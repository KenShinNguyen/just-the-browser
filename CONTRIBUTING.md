# Contributing to Just the Browser

Do you want to help improve Just the Browser? Here's what you need to know.

### Configuration changes

**New configuration settings should be discussed in an issue on GitHub first.** Everyone's definition of bloatware and privacy is different, and Just the Browser aims more for sensible defaults rather than a fully locked-down experience. Pull requests or other requests to turn of Google Safe Browsing, search engine auto-complete suggestions, or other similar functionality will not be considered. 

If you are contributing updates to the browser configuration settings, your changes should be synchronized across the configuration files for all platforms. In the browser's directory (e.g. `chrome` or `firefox`):

1. Add the setting to `install.reg` for Windows systems
2. Add the setting to the `.mobileconfig` file for macOS
3. Add the setting to the `.json` file for Linux (if there is one)
4. Add the setting and an explanation of the change to the README.md file

Run the validation script before opening a pull request. It checks that every
setting is present with the same value in all of the configuration files for
that browser, that it is documented in the README.md table, and that the files
themselves are well-formed:

```shell
python3 scripts/validate_configs.py
```

The same script runs on every pull request in the `validate.yml` GitHub Action,
together with ShellCheck for `main.sh`, PSScriptAnalyzer for `main.ps1`, and a
test build of the website. If a setting only applies to one platform, add it to
the `PLATFORM_ONLY` list in the script with a comment explaining why.

### Keeping up with upstream

This repository is a fork of
[corbindavenport/just-the-browser](https://github.com/corbindavenport/just-the-browser).
Upstream adds policies as browsers ship new AI and telemetry features, so a fork
that does not follow along quietly stops working: a user believes a feature is
turned off when nothing is turning it off any more.

The `upstream_drift.yml` GitHub Action compares this fork's policies with
upstream every week. It compares the parsed policies rather than the file text,
so the fork's own URL and branding changes are not reported as differences.

Issues are disabled on this fork, so a drift is reported by failing the workflow
run and writing the details to the run summary — GitHub emails the repository
owner when a scheduled run fails. If Issues are enabled later, the workflow could
file the report as an issue instead.

To run the same comparison yourself:

```shell
git clone --depth 1 https://github.com/corbindavenport/just-the-browser /tmp/upstream
python3 scripts/check_upstream_drift.py /tmp/upstream
```

If this fork deliberately differs on a policy, add its name to
`scripts/upstream_divergence.json` with a note in `_notes`, and it stops being
reported.

### Downloaded files are checked before they are installed

`main.sh` and `main.ps1` fetch configuration over the network and apply it with
administrator or root access. A captive portal, a proxy notice, or an error page
served with a `200` status would otherwise be written straight onto a live policy
path or handed to `reg.exe`.

Both scripts now download to a temporary location first and check the file is
the kind it should be — JSON for the Linux policy files, a property list for the
macOS profiles, and a `Windows Registry Editor Version 5.00` header for the
registry files — before anything is installed. A failed check leaves any existing
configuration untouched. If you add a new download, route it through
`_fetch_verified` / `_install_json` in `main.sh` or `Import-RemoteRegistryFile`
in `main.ps1` rather than calling `curl` or `Invoke-WebRequest` directly.

### Working on the scripts

The Windows script is a **PowerShell v5.0** script, so it can run out of the box on Windows 8.1, Windows 10, and Windows 11.

If you are working on the script, please ensure you are not using PowerShell features or syntax from later versions, such as PowerShell 7/PowerShell Core.

The Linux and macOS script is a Bash script. The baseline testing environment is the **Bash v3.2** shell bundled with macOS.

### Testing with another branch or repository

You can run the scripts with a different base URL with a command-line argument. Here's how to do it on macOS/Linux:

```bash
./main.sh "https://raw.githubusercontent.com/KenShinNguyen/just-the-browser/newbranch"
```

Here's how to do it on Windows:

```powershell
./main.ps1 "https://raw.githubusercontent.com/KenShinNguyen/just-the-browser/newbranch"
```

The alternative base URL should **not** have an ending forward slash (/).

### Working on the website

With Node.js and NPM installed, you can preview the site with `npm start`, and
run the same checks CI runs with `npm test`.