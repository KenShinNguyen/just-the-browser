#!/usr/bin/env python3
"""Compare this fork's browser policies against the upstream project.

This repository is a fork of corbindavenport/just-the-browser, and the whole
point of the project is the list of policies it applies. Upstream adds policies
as browsers ship new AI and telemetry features, so a fork that does not track
those changes quietly stops doing its job: users believe a feature is turned off
when nothing is switching it off any more.

The comparison is done on the parsed policies rather than on the file text, so
it does not report the fork's own URL and branding changes as differences.

Deliberate differences can be recorded in scripts/upstream_divergence.json:

    {
      "chrome": ["SomePolicyWeDropped"],
      "_comment": "why each of these differs"
    }

Usage:
    python3 scripts/check_upstream_drift.py <path to upstream checkout>

Exits 0 when the fork is in sync, 1 when there is drift to look at.
"""

import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from validate_configs import BROWSERS, canonical, parse_reg  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIVERGENCE_FILE = os.path.join(ROOT, "scripts", "upstream_divergence.json")


def load_divergence():
    """Policies this fork deliberately differs on, per browser."""
    if not os.path.exists(DIVERGENCE_FILE):
        return {}
    with open(DIVERGENCE_FILE, encoding="utf-8") as handle:
        data = json.load(handle)
    return {k: set(v) for k, v in data.items() if not k.startswith("_")}


def flatten(policies, prefix=""):
    """Flatten nested policies so Firefox's groups compare one key at a time."""
    flat = {}
    for name, value in policies.items():
        key = "%s%s" % (prefix, name)
        if isinstance(value, dict):
            flat.update(flatten(value, key + "."))
        else:
            flat[key] = canonical(value)
    return flat


def upstream_revision(path):
    try:
        out = subprocess.check_output(
            ["git", "-C", path, "log", "-1", "--format=%h %ad %s", "--date=short"],
            stderr=subprocess.DEVNULL,
        )
        return out.decode("utf-8", "replace").strip()
    except Exception:  # noqa: BLE001 - the revision is only used for the report
        return "unknown"


def compare_browser(browser, config, upstream_root):
    """Return (missing, extra, changed) for one browser."""
    ours_path = os.path.join(ROOT, browser, "install.reg")
    theirs_path = os.path.join(upstream_root, browser, "install.reg")
    if not os.path.exists(theirs_path):
        return None
    ours = flatten(parse_reg(ours_path, config["reg_root"]))
    theirs = flatten(parse_reg(theirs_path, config["reg_root"]))

    missing = sorted(set(theirs) - set(ours))
    extra = sorted(set(ours) - set(theirs))
    changed = sorted(
        name for name in set(ours) & set(theirs) if ours[name] != theirs[name]
    )
    return missing, extra, changed, ours, theirs


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    upstream_root = sys.argv[1]
    if not os.path.isdir(upstream_root):
        print("error: %s is not a directory" % upstream_root)
        return 2

    divergence = load_divergence()
    lines = []
    drift = False

    # A browser upstream supports that this fork does not have at all
    for name in sorted(os.listdir(upstream_root)):
        if name in BROWSERS or name.startswith("."):
            continue
        if os.path.exists(os.path.join(upstream_root, name, "install.reg")):
            lines.append("### New browser upstream: `%s`" % name)
            lines.append("")
            lines.append("Upstream has a `%s/` configuration this fork does "
                         "not know about." % name)
            lines.append("")
            drift = True

    for browser, config in sorted(BROWSERS.items()):
        result = compare_browser(browser, config, upstream_root)
        if result is None:
            lines.append("### `%s`" % browser)
            lines.append("")
            lines.append("Not present upstream any more.")
            lines.append("")
            drift = True
            continue
        missing, extra, changed, ours, theirs = result
        allowed = divergence.get(browser, set())
        missing = [p for p in missing if p not in allowed]
        extra = [p for p in extra if p not in allowed]
        changed = [p for p in changed if p not in allowed]
        if not (missing or extra or changed):
            continue

        drift = True
        lines.append("### `%s`" % browser)
        lines.append("")
        if missing:
            lines.append("**Upstream has these, this fork does not** "
                         "— the fork is behind:")
            lines.append("")
            for name in missing:
                lines.append("- `%s` = `%s`" % (name, theirs[name]))
            lines.append("")
        if changed:
            lines.append("**Different values:**")
            lines.append("")
            lines.append("| Policy | This fork | Upstream |")
            lines.append("| --- | --- | --- |")
            for name in changed:
                lines.append("| `%s` | `%s` | `%s` |"
                             % (name, ours[name], theirs[name]))
            lines.append("")
        if extra:
            lines.append("**Only in this fork** — intentional, or left over:")
            lines.append("")
            for name in extra:
                lines.append("- `%s` = `%s`" % (name, ours[name]))
            lines.append("")

    revision = upstream_revision(upstream_root)
    if not drift:
        print("No policy drift. Upstream is at: %s" % revision)
        return 0

    print("This fork's browser policies differ from upstream "
          "(corbindavenport/just-the-browser).")
    print("")
    print("Upstream revision compared against: `%s`" % revision)
    print("")
    print("\n".join(lines))
    print("If a difference is deliberate, add the policy name to "
          "`scripts/upstream_divergence.json` so it stops being reported.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
