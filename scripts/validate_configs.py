#!/usr/bin/env python3
"""Validate the Just the Browser configuration files.

CONTRIBUTING.md asks that every setting is added to the Windows Registry file,
the macOS .mobileconfig file, and the Linux JSON file (where one exists), and
that it is documented in the browser's README.md. Nothing enforced that, so a
setting could be added to one platform and silently forgotten on the others.

This script checks:

  1. Every .json, .mobileconfig, and .reg file parses.
  2. Each .mobileconfig has well-formed payload metadata, and browsers that
     ship several payloads (Edge channels, Firefox channels) apply identical
     policies to each one.
  3. The policies in install.reg, the .mobileconfig, and the JSON file are the
     same set with the same values, apart from the documented exceptions below.
  4. uninstall.reg removes exactly what install.reg creates.
  5. Every policy is documented in the browser's README.md table.
  6. The profile names the install scripts tell macOS users to look for match
     the PayloadDisplayName actually in the .mobileconfig.

Run it with: python3 scripts/validate_configs.py
"""

import json
import os
import plistlib
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Browser directories, and the registry key that holds their policies.
BROWSERS = {
    "chrome": {
        "reg_root": r"HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Google\Chrome",
        "mobileconfig": "chrome.mobileconfig",
        "json": "managed_policies.json",
        "json_root": None,
    },
    "edge": {
        "reg_root": r"HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Edge",
        "mobileconfig": "edge.mobileconfig",
        # Edge on Linux is not supported by the install script yet
        "json": None,
        "json_root": None,
    },
    "firefox": {
        "reg_root": r"HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Mozilla\Firefox",
        "mobileconfig": "firefox.mobileconfig",
        "json": "policies.json",
        # Firefox wraps everything in a top-level "policies" object
        "json_root": "policies",
    },
    "brave": {
        "reg_root": r"HKEY_LOCAL_MACHINE\Software\Policies\BraveSoftware\Brave",
        "mobileconfig": "brave.mobileconfig",
        "json": "managed_policies.json",
        "json_root": None,
    },
}

# Policies that legitimately exist on only some platforms. Anything not listed
# here has to be present in every configuration file for that browser.
PLATFORM_ONLY = {
    # Firefox on macOS needs policies switched on explicitly; on Windows and
    # Linux the presence of the registry keys / policies.json is enough.
    ("firefox", "mobileconfig"): {"EnterprisePoliciesEnabled"},
}

# Extra registry keys install.reg is allowed to create outside the policy root,
# so the configuration shows up in Windows' installed programs list.
UNINSTALL_ENTRY = r"Software\Microsoft\Windows\CurrentVersion\Uninstall"

errors = []
warnings = []


def error(message):
    errors.append(message)


def warn(message):
    warnings.append(message)


def canonical(value):
    """Reduce a policy value to a form comparable across all three formats.

    A Windows dword can only express a boolean as 0 or 1, so booleans and the
    integers 0 and 1 have to compare equal.
    """
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, list):
        return [canonical(v) for v in value]
    if isinstance(value, dict):
        return {k: canonical(v) for k, v in value.items()}
    return value


def parse_reg(path, reg_root):
    """Parse a .reg file into a nested dict of the policies below reg_root."""
    policies = {}
    section = None
    with open(path, encoding="utf-8-sig") as handle:
        for number, raw in enumerate(handle, 1):
            line = raw.strip()
            if not line or line.startswith(";"):
                continue
            if line.startswith("Windows Registry Editor"):
                continue
            match = re.match(r"^\[(-?)(.+)\]$", line)
            if match:
                section = match.group(2)
                continue
            match = re.match(r'^"([^"]+)"=(.*)$', line)
            if not match:
                error("%s:%d: cannot parse line: %s" % (path, number, line))
                continue
            if section is None:
                error("%s:%d: value outside of any registry key" % (path, number))
                continue
            if UNINSTALL_ENTRY.lower() in section.lower():
                continue
            if not section.lower().startswith(reg_root.lower()):
                error("%s:%d: value in unexpected key %s" % (path, number, section))
                continue

            name, literal = match.group(1), match.group(2)
            if literal.startswith("dword:"):
                value = int(literal[len("dword:"):], 16)
            elif literal.startswith('"') and literal.endswith('"'):
                value = literal[1:-1].replace('\\"', '"').replace("\\\\", "\\")
            else:
                error("%s:%d: unsupported value type: %s" % (path, number, literal))
                continue

            # Walk down into the nested key the value lives under
            relative = section[len(reg_root):].strip("\\")
            target = policies
            for part in [p for p in relative.split("\\") if p]:
                target = target.setdefault(part, {})
            target[name] = value

    # A key whose value names are all numbers is a list, like SearchEngines\Remove
    def collapse(node):
        if not isinstance(node, dict):
            return node
        node = {k: collapse(v) for k, v in node.items()}
        if node and all(k.isdigit() for k in node):
            return [node[k] for k in sorted(node, key=int)]
        return node

    return collapse(policies)


def reg_sections(path):
    """Return the list of (deleted, key) sections declared in a .reg file."""
    sections = []
    with open(path, encoding="utf-8-sig") as handle:
        for line in handle:
            match = re.match(r"^\[(-?)(.+)\]$", line.strip())
            if match:
                sections.append((match.group(1) == "-", match.group(2)))
    return sections


def parse_mobileconfig(path):
    """Return (top_level_dict, [payload policy dicts]) for a .mobileconfig."""
    with open(path, "rb") as handle:
        profile = plistlib.load(handle)
    payloads = profile.get("PayloadContent", [])
    policy_sets = []
    for payload in payloads:
        policy_sets.append(
            {k: v for k, v in payload.items() if not k.startswith("Payload")}
        )
    return profile, payloads, policy_sets


def check_payload_metadata(path, profile, payloads):
    required_top = [
        "PayloadDisplayName",
        "PayloadIdentifier",
        "PayloadType",
        "PayloadUUID",
        "PayloadVersion",
    ]
    for key in required_top:
        if key not in profile:
            error("%s: top-level profile is missing %s" % (path, key))
    if not isinstance(profile.get("PayloadVersion"), int) or isinstance(
        profile.get("PayloadVersion"), bool
    ):
        error(
            "%s: top-level PayloadVersion must be an integer, found %r"
            % (path, profile.get("PayloadVersion"))
        )
    if profile.get("PayloadType") != "Configuration":
        error("%s: top-level PayloadType must be 'Configuration'" % path)
    if not payloads:
        error("%s: profile has no PayloadContent" % path)

    uuid_pattern = re.compile(
        r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
        r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
    )
    seen_uuids = {}
    for index, payload in enumerate(payloads):
        label = "%s: payload %d (%s)" % (
            path,
            index + 1,
            payload.get("PayloadDisplayName", "unnamed"),
        )
        for key in required_top:
            if key not in payload:
                error("%s is missing %s" % (label, key))
        version = payload.get("PayloadVersion")
        if not isinstance(version, int) or isinstance(version, bool):
            error("%s has PayloadVersion %r, expected an integer" % (label, version))
        uuid = payload.get("PayloadUUID", "")
        if not uuid_pattern.match(str(uuid)):
            error("%s has a malformed PayloadUUID: %r" % (label, uuid))
        if uuid in seen_uuids:
            error("%s reuses the PayloadUUID of %s" % (label, seen_uuids[uuid]))
        seen_uuids[uuid] = label


def compare(browser, source_a, policies_a, source_b, policies_b):
    """Report policies that differ between two configuration files."""
    exempt_a = PLATFORM_ONLY.get((browser, source_a), set())
    exempt_b = PLATFORM_ONLY.get((browser, source_b), set())

    only_a = set(policies_a) - set(policies_b) - exempt_a
    only_b = set(policies_b) - set(policies_a) - exempt_b
    for name in sorted(only_a):
        error(
            "%s: %s sets %s but %s does not"
            % (browser, source_a, name, source_b)
        )
    for name in sorted(only_b):
        error(
            "%s: %s sets %s but %s does not"
            % (browser, source_b, name, source_a)
        )
    for name in sorted(set(policies_a) & set(policies_b)):
        value_a = canonical(policies_a[name])
        value_b = canonical(policies_b[name])
        if value_a != value_b:
            error(
                "%s: %s is %r in %s but %r in %s"
                % (browser, name, policies_a[name], source_a,
                   policies_b[name], source_b)
            )


def readme_documented_names(path):
    """Return the names in the first column of the README's settings table."""
    names = set()
    for line in open(path, encoding="utf-8"):
        if not line.startswith("|"):
            continue
        first = line.strip().strip("|").split("|")[0].strip().strip("`")
        if first and not set(first) <= set("- :"):
            names.add(first)
    return names


def check_browser(browser, config):
    directory = os.path.join(ROOT, browser)
    sources = {}

    install_reg = os.path.join(directory, "install.reg")
    uninstall_reg = os.path.join(directory, "uninstall.reg")
    sources["install.reg"] = parse_reg(install_reg, config["reg_root"])

    mobileconfig = os.path.join(directory, config["mobileconfig"])
    profile, payloads, policy_sets = parse_mobileconfig(mobileconfig)
    check_payload_metadata(mobileconfig, profile, payloads)
    if policy_sets:
        # Every channel in the profile has to get the same policies
        for index, policies in enumerate(policy_sets[1:], start=2):
            if canonical(policies) != canonical(policy_sets[0]):
                error(
                    "%s: payload %d applies different policies than payload 1"
                    % (mobileconfig, index)
                )
        sources["mobileconfig"] = policy_sets[0]

    if config["json"]:
        json_path = os.path.join(directory, config["json"])
        with open(json_path, encoding="utf-8") as handle:
            data = json.load(handle)
        if config["json_root"]:
            if config["json_root"] not in data:
                error("%s: missing top-level %r object"
                      % (json_path, config["json_root"]))
                data = {}
            else:
                data = data[config["json_root"]]
        sources[config["json"]] = data

    # Cross-platform parity
    names = list(sources)
    for i in range(len(names)):
        for j in range(i + 1, len(names)):
            compare(browser, names[i], sources[names[i]],
                    names[j], sources[names[j]])

    # uninstall.reg has to delete every key install.reg creates
    created = {key for deleted, key in reg_sections(install_reg) if not deleted}
    removed = {key.lower() for deleted, key in reg_sections(uninstall_reg) if deleted}
    for key in sorted(created):
        # Deleting a parent key removes its subkeys too, but only a whole key:
        # deleting ...\Microsoft\Edge does not remove ...\Microsoft\EdgeUpdate
        lowered = key.lower()
        if not any(lowered == r or lowered.startswith(r + "\\") for r in removed):
            error("%s: uninstall.reg does not remove %s" % (browser, key))

    # Every policy is documented
    readme = os.path.join(directory, "README.md")
    documented = readme_documented_names(readme)
    for name in sorted(sources["install.reg"]):
        if name not in documented:
            error("%s: %s is not documented in %s/README.md"
                  % (browser, name, browser))

    return profile


def check_script_profile_names(profiles):
    """The scripts tell macOS users which profile to click, so the name has to match."""
    script = os.path.join(ROOT, "main.sh")
    text = open(script, encoding="utf-8").read()
    known = {browser: profile.get("PayloadDisplayName", "")
             for browser, profile in profiles.items()}
    # Some prompts quote the profile name and some do not, so both forms count
    for quoted in sorted(set(re.findall(r"then (?:open|select) '?(.+?)'? and click", text))):
        if quoted not in known.values():
            error(
                "main.sh tells the user to look for the profile %r, which is not "
                "the PayloadDisplayName of any .mobileconfig (found: %s)"
                % (quoted, ", ".join(sorted(repr(v) for v in known.values())))
            )


def check_json_files():
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames
                       if d not in (".git", "node_modules", "_site")]
        for name in filenames:
            if not name.endswith(".json") or name == "package-lock.json":
                continue
            path = os.path.join(dirpath, name)
            try:
                with open(path, encoding="utf-8") as handle:
                    json.load(handle)
            except ValueError as exc:
                error("%s: invalid JSON: %s" % (os.path.relpath(path, ROOT), exc))


def main():
    check_json_files()
    profiles = {}
    for browser, config in sorted(BROWSERS.items()):
        try:
            profiles[browser] = check_browser(browser, config)
        except Exception as exc:  # noqa: BLE001 - report and keep checking
            error("%s: could not be validated: %s" % (browser, exc))
    check_script_profile_names(profiles)

    for message in warnings:
        print("warning: %s" % message)
    for message in errors:
        print("error: %s" % message)

    if errors:
        print("\n%d problem(s) found." % len(errors))
        return 1
    print("All browser configuration files are valid and in sync.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
