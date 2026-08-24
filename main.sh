#!/bin/bash

# Allow alternate base URL as first command-line argument, for testing and development
if [ -z "$1" ]; then
    BASEURL="https://raw.githubusercontent.com/KenShinNguyen/just-the-browser/main"
else
    BASEURL="$1"
fi

# Version of the browser policies this copy of the script installs. It is shown
# in the header, so a user reporting a browser problem can say which policy set
# they applied. scripts/validate_configs.py keeps this in step with the VERSION
# file and with main.ps1.
POLICY_VERSION="2026.08.24"

OS=$(uname)
MICROSOFT_EDGE_MAC_CONFIG="$BASEURL/edge/edge.mobileconfig"
GOOGLE_CHROME_MAC_CONFIG="$BASEURL/chrome/chrome.mobileconfig"
FIREFOX_MAC_CONFIG="$BASEURL/firefox/firefox.mobileconfig"
FIREFOX_SETTINGS="$BASEURL/firefox/policies.json"
CHROME_SETTINGS="$BASEURL/chrome/managed_policies.json"
BRAVE_SETTINGS="$BASEURL/brave/managed_policies.json"
BRAVE_MAC_CONFIG="$BASEURL/brave/brave.mobileconfig"

# Generate a temporary directory on macOS instead of broken default $TMPDIR
if [ "$OS" = "Darwin" ]; then
    TMPDIR=$(mktemp -d) || { echo "Could not create a temporary directory."; exit 1; }
fi

# Get command to run as root
SUDO=$(which sudo)
DOAS=$(which doas)
if [[ -f "${SUDO}" && -x "${SUDO}" ]]; then
    AS_ROOT="${SUDO}"
elif [[ -f "${DOAS}" && -x "${DOAS}" ]]; then
    AS_ROOT="${DOAS}"
else
    echo "No option to run as root, your system does not have sudo or doas installed."
    exit 1
fi

# Confirm that root access is available
_confirm_root() {
    if [ "$EUID" != 0 ]; then
        echo "Root access is required for this step."
        "${AS_ROOT}" echo "Root access granted." || { echo "Exiting."; exit 1; }
    fi
}

# Remove Firefox JSON file on macOS if it exists, so it does not conflict with the .mobileconfig file
# Previous versions of Just the Browser used the JSON method
_legacy_cleanup() {
    if [ "$OS" = "Darwin" ] && [ -e "/Applications/Firefox.app/Contents/Resources/distribution/policies.json" ]; then
        echo "Previous Firefox policies.json file found, deleting..."
        _confirm_root
        "${AS_ROOT}" rm "/Applications/Firefox.app/Contents/Resources/distribution/policies.json" || { read -p "Remove failed! Press Enter/Return to continue."; return; }
    fi
}

# Download a file and check that it is the kind of file we asked for, before
# anything is written to a live policy path. A captive portal, a proxy notice or
# an error page served with a 200 status would otherwise be installed as
# configuration, or handed to the browser as policy.
# Usage: _fetch_verified <url> <json|plist> <output path>
_fetch_verified() {
    local url="$1"
    local kind="$2"
    local out="$3"
    local first
    curl -Lfs -o "$out" "$url" || { echo "Download failed."; return 1; }
    if [ ! -s "$out" ]; then
        echo "The downloaded file is empty."
        return 1
    fi
    # The first non-whitespace character is enough to spot an HTML page
    first=$(head -c 512 "$out" | tr -d '[:space:]' | cut -c1)
    if [ "$kind" = "json" ]; then
        if [ "$first" != "{" ]; then
            echo "The downloaded file is not a JSON configuration file."
            return 1
        fi
        # python3 is not part of the baseline, so only use it when it is there
        if [ -x "$(command -v python3)" ]; then
            python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$out" 2>/dev/null || {
                echo "The downloaded file is not valid JSON."
                return 1
            }
        fi
    elif [ "$kind" = "plist" ]; then
        if [ "$first" != "<" ] || ! grep -q "<!DOCTYPE plist" "$out"; then
            echo "The downloaded file is not a configuration profile."
            return 1
        fi
        # plutil ships with macOS, which is the only place profiles are used
        if [ -x "$(command -v plutil)" ]; then
            plutil -lint "$out" >/dev/null 2>&1 || {
                echo "The downloaded configuration profile is not valid."
                return 1
            }
        fi
    fi
    return 0
}

# Download a policy file, check it, and only then copy it into place. The file
# is verified in a temporary location so a bad download never overwrites a
# working configuration.
# Usage: _install_json <url> <directory> <filename> [root]
_install_json() {
    local url="$1"
    local dir="$2"
    local name="$3"
    local as_root="$4"
    local tmp
    tmp=$(mktemp) || { echo "Could not create a temporary file."; return 1; }
    if ! _fetch_verified "$url" json "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! _place_file "$tmp" "$dir" "$name" "$as_root"; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    return 0
}

# Copy an already downloaded and checked file into a policy directory.
# Usage: _place_file <source file> <directory> <filename> [root]
_place_file() {
    local src="$1"
    local dir="$2"
    local name="$3"
    local as_root="$4"
    local run=""
    if [ "$as_root" = "root" ]; then
        run="${AS_ROOT}"
    fi
    $run mkdir -p "$dir" || return 1
    $run cp "$src" "$dir/$name" || return 1
    # mktemp creates the file as 600, but the browser reads policies as the
    # normal user, so the installed copy has to be world readable
    $run chmod 644 "$dir/$name" || return 1
    return 0
}

# Render initial interface for all pages
_show_header() {
    clear
    echo -e "\nJust the Browser ($OS)\n========\nPolicy version: $POLICY_VERSION\nSource: $BASEURL\n"
}

# Install Google Chrome settings
_install_chrome() {
    _show_header
    echo "Downloading configuration, please wait..."
    if [ "$OS" = "Darwin" ]; then
        # Download and open configuration file
        _fetch_verified "$GOOGLE_CHROME_MAC_CONFIG" plist "$TMPDIR/chrome.mobileconfig" || { read -p "Press Enter/Return to continue."; return; }
        open "$TMPDIR/chrome.mobileconfig"
        open -b "com.apple.systempreferences"
        # Prompt user to accept file
        echo -e "\nIn the System Settings application, navigate to General > Device Management, then open Google Chrome settings and click the Install button.\n\nIn older macOS versions with System Preferences, this is in the Profiles section.\n"
        read -p "Press Enter/Return to continue."
    else
        _confirm_root
        _install_json "$CHROME_SETTINGS" "/etc/opt/chrome/policies/managed" "managed_policies.json" root || { read -p "Press Enter/Return to continue."; return; }
        read -p "Installed Chrome settings. Press Enter/Return to continue."
    fi
}

# Remove Google Chrome settings
_uninstall_chrome() {
    _show_header
    if [ "$OS" = "Darwin" ]; then
        open -b "com.apple.systempreferences"
        echo -e "\nIn the System Settings application, navigate to General > Device Management, then select 'Google Chrome settings' and click the remove (-) button.\n\nIn older macOS versions with System Preferences, this is in the Profiles section.\n"
        read -p "Press Enter/Return to continue."
    else
        _confirm_root
        if [ -e "/etc/opt/chrome/policies/managed/managed_policies.json" ]; then
            "${AS_ROOT}" rm "/etc/opt/chrome/policies/managed/managed_policies.json" || { read -p "Remove failed! Press Enter/Return to continue."; return; }
        fi
        read -p "Removed Chrome settings. Press Enter/Return to continue."
    fi
}

# Install Chromium settings
_install_chromium() {
    _show_header
    echo "Downloading configuration, please wait..."
    _confirm_root
    # Chromium reads its policies from a different directory depending on how the
    # distribution packages it, and there is no reliable way to tell which one a
    # given build will use, so both are written. The file is downloaded and
    # checked once and then copied to each path, rather than fetched twice.
    local tmp
    tmp=$(mktemp) || { read -p "Could not create a temporary file. Press Enter/Return to continue."; return; }
    if ! _fetch_verified "$CHROME_SETTINGS" json "$tmp"; then
        rm -f "$tmp"
        read -p "Press Enter/Return to continue."
        return
    fi
    # /etc/chromium-browser/policies/managed for Ubuntu and related distributions
    _place_file "$tmp" "/etc/chromium-browser/policies/managed" "managed_policies.json" root || { rm -f "$tmp"; read -p "Install failed! Press Enter/Return to continue."; return; }
    # /etc/chromium/policies/managed for other distributions
    _place_file "$tmp" "/etc/chromium/policies/managed" "managed_policies.json" root || { rm -f "$tmp"; read -p "Install failed! Press Enter/Return to continue."; return; }
    rm -f "$tmp"
    # Completed
    read -p "Installed Chromium settings. Press Enter/Return to continue."
}

# Remove Google Chrome settings
_uninstall_chromium() {
    _show_header
    _confirm_root
    # Uninstall from /etc/chromium-browser/policies/managed for Ubuntu and related distributions
    if [ -e "/etc/chromium-browser/policies/managed/managed_policies.json" ]; then
        "${AS_ROOT}" rm "/etc/chromium-browser/policies/managed/managed_policies.json" || { read -p "Remove failed! Press Enter/Return to continue."; return; }
    fi
    # Uninstall from /etc/chromium/policies/managed for other distributions
    if [ -e "/etc/chromium/policies/managed/managed_policies.json" ]; then
        "${AS_ROOT}" rm "/etc/chromium/policies/managed/managed_policies.json" || { read -p "Remove failed! Press Enter/Return to continue."; return; }
    fi
    read -p "Removed Chromium settings. Press Enter/Return to continue."
}

# Install Chromium settings for Flatpak
_install_chromium_flatpak() {
    _show_header
    FLATPAK_ARCH=$(flatpak --default-arch)
    FLATPAK_PATH="$HOME/.local/share/flatpak/extension/org.chromium.Chromium.Extension.just-the-browser/$FLATPAK_ARCH/1/policies/managed"
    _install_json "$CHROME_SETTINGS" "$FLATPAK_PATH" "managed_policies.json" || { read -p "Press Enter/Return to continue."; return; }
    read -p "Installed Chromium settings. Press Enter/Return to continue."
}

# Remove Chromium settings for Flatpak
_uninstall_chromium_flatpak() {
    _show_header
    FLATPAK_ARCH=$(flatpak --default-arch)
    FLATPAK_PATH="$HOME/.local/share/flatpak/extension/org.chromium.Chromium.Extension.just-the-browser/$FLATPAK_ARCH/1/policies/managed"
    if [ -e "$FLATPAK_PATH/managed_policies.json" ]; then
        rm "$FLATPAK_PATH/managed_policies.json" || { read -p "Remove failed! Press Enter/Return to continue."; return; }
    fi
    read -p "Removed Chromium settings. Press Enter/Return to continue."
}

# Install Microsoft Edge settings
_install_edge() {
    _show_header
    echo "Downloading configuration, please wait..."
    # Download and open configuration file
    _fetch_verified "$MICROSOFT_EDGE_MAC_CONFIG" plist "$TMPDIR/edge.mobileconfig" || { read -p "Press Enter/Return to continue."; return; }
    open "$TMPDIR/edge.mobileconfig"
    open -b "com.apple.systempreferences"
    # Prompt user to accept file
    echo -e "\nIn the System Settings application, navigate to General > Device Management, then open Microsoft Edge settings and click the Install button.\n\nIn older macOS versions with System Preferences, this is in the Profiles section.\n"
    read -p "Press Enter/Return to continue."
}

# Remove Microsoft Edge settings
_uninstall_edge() {
    _show_header
    open -b "com.apple.systempreferences"
    echo -e "\nIn the System Settings application, navigate to General > Device Management, then select 'Microsoft Edge settings' and click the remove (-) button.\n\nIn older macOS versions with System Preferences, this is in the Profiles section.\n"
    read -p "Press Enter/Return to continue."
}

# Install Firefox settings
_install_firefox() {
    _show_header
    _legacy_cleanup
    echo "Downloading configuration, please wait..."
    if [ "$OS" = "Darwin" ]; then
        # Download and open configuration file
        _fetch_verified "$FIREFOX_MAC_CONFIG" plist "$TMPDIR/firefox.mobileconfig" || { read -p "Press Enter/Return to continue."; return; }
        open "$TMPDIR/firefox.mobileconfig"
        open -b "com.apple.systempreferences"
        # Prompt user to accept file
        echo -e "\nIn the System Settings application, navigate to General > Device Management, then open 'Mozilla Firefox settings' and click the Install button.\n\nIn older macOS versions with System Preferences, this is in the Profiles section.\n"
        read -p "Press Enter/Return to continue."
    else
        _confirm_root
        _install_json "$FIREFOX_SETTINGS" "/etc/firefox/policies" "policies.json" root || { read -p "Press Enter/Return to continue."; return; }
        read -p "Updated Firefox settings. Press Enter/Return to continue."
    fi
}

# Remove Firefox settings
_uninstall_firefox() {
    _show_header
    _legacy_cleanup
    if [ "$OS" = "Darwin" ]; then
        open -b "com.apple.systempreferences"
        echo -e "\nIn the System Settings application, navigate to General > Device Management, then select 'Mozilla Firefox settings' and click the remove (-) button.\n\nIn older macOS versions with System Preferences, this is in the Profiles section.\n"
        read -p "Press Enter/Return to continue."
    else
         _confirm_root
        if [ -e "/etc/firefox/policies/policies.json" ]; then
            "${AS_ROOT}" rm "/etc/firefox/policies/policies.json" || { read -p "Remove failed! Press Enter/Return to continue."; return; }
        fi
        read -p "Removed Firefox settings. Press Enter/Return to continue.";
    fi
}

# Install Firefox settings for Flatpak
_install_firefox_flatpak() {
    _show_header
    FLATPAK_ARCH=$(flatpak --default-arch)
    FLATPAK_PATH="$HOME/.local/share/flatpak/extension/org.mozilla.firefox.systemconfig/$FLATPAK_ARCH/stable/policies"
    _install_json "$FIREFOX_SETTINGS" "$FLATPAK_PATH" "policies.json" || { read -p "Press Enter/Return to continue."; return; }
    read -p "Installed Firefox settings. Press Enter/Return to continue."
}

# Remove Firefox settings for Flatpak
_uninstall_firefox_flatpak() {
    _show_header
    FLATPAK_ARCH=$(flatpak --default-arch)
    FLATPAK_PATH="$HOME/.local/share/flatpak/extension/org.mozilla.firefox.systemconfig/$FLATPAK_ARCH/stable/policies"
    if [ -e "$FLATPAK_PATH/policies.json" ]; then
        rm "$FLATPAK_PATH/policies.json" || { read -p "Remove failed! Press Enter/Return to continue."; return; }
    fi
    read -p "Removed Firefox settings. Press Enter/Return to continue."
}

# Install Brave settings
_install_brave() {
    _show_header
    echo "Downloading configuration, please wait..."
    if [ "$OS" = "Darwin" ]; then
        # Download and open configuration file
        _fetch_verified "$BRAVE_MAC_CONFIG" plist "$TMPDIR/brave.mobileconfig" || { read -p "Press Enter/Return to continue."; return; }
        open "$TMPDIR/brave.mobileconfig"
        open -b "com.apple.systempreferences"
        # Prompt user to accept file
        echo -e "\nIn the System Settings application, navigate to General > Device Management, then open 'Brave Browser settings' and click the Install button.\n\nIn older macOS versions with System Preferences, this is in the Profiles section.\n"
        read -p "Press Enter/Return to continue."
    else
        _confirm_root
        _install_json "$BRAVE_SETTINGS" "/etc/brave/policies/managed" "managed_policies.json" root || { read -p "Press Enter/Return to continue."; return; }
        read -p "Installed Brave settings. Press Enter/Return to continue."
    fi
}

# Remove Brave settings
_uninstall_brave() {
    _show_header
    if [ "$OS" = "Darwin" ]; then
        open -b "com.apple.systempreferences"
        echo -e "\nIn the System Settings application, navigate to General > Device Management, then select 'Brave Browser settings' and click the remove (-) button.\n\nIn older macOS versions with System Preferences, this is in the Profiles section.\n"
        read -p "Press Enter/Return to continue."
    else
        _confirm_root
        if [ -e "/etc/brave/policies/managed/managed_policies.json" ]; then
            "${AS_ROOT}" rm "/etc/brave/policies/managed/managed_policies.json" || { read -p "Remove failed! Press Enter/Return to continue."; return; }
        fi
        read -p "Removed Brave settings. Press Enter/Return to continue."
    fi
}

# Main menu selection
_main() {
    # The menu is rebuilt on every pass, so the "Remove settings" options appear
    # or disappear as soon as a configuration is installed or removed
    while true; do
        # Create list for menu options
        declare -a options=()
        # Google Chrome without settings applied
        if [ "$OS" = "Darwin" ]; then
            options+=("Google Chrome: Update settings")
        elif [ "$OS" = "Linux" ] && { [ -x "$(command -v google-chrome)" ] || [ -x "$(command -v google-chrome-stable)" ]; }; then
            options+=("Google Chrome: Update settings")
        fi
        # Google Chrome with settings already applied
        if [ "$OS" = "Darwin" ]; then
            options+=("Google Chrome: Remove settings")
        elif [ "$OS" = "Linux" ] && [ -e "/etc/opt/chrome/policies/managed/managed_policies.json" ]; then
            options+=("Google Chrome: Remove settings")
        fi
        # Chromium without settings applied
        if [ "$OS" = "Linux" ] && { [ -x "$(command -v chromium-browser)" ] || [ -x "$(command -v chromium)" ]; }; then
            options+=("Chromium: Update settings")
        fi
        # Chromium with settings already applied
        if [ "$OS" = "Linux" ] && [ -e "/etc/chromium-browser/policies/managed/managed_policies.json" ]; then
            options+=("Chromium: Remove settings")
        elif [ "$OS" = "Linux" ] && [ -e "/etc/chromium/policies/managed/managed_policies.json" ]; then
            options+=("Chromium: Remove settings")
        fi
        # Chromium Flatpak
        if [ "$OS" = "Linux" ] && [ -x "$(command -v flatpak)" ] && flatpak list | grep -q "org.chromium.Chromium"; then
            options+=("Chromium Flatpak: Update settings")
            options+=("Chromium Flatpak: Remove settings")
        fi
        # Microsoft Edge
        if [ "$OS" = "Darwin" ]; then
            options+=("Microsoft Edge: Update settings")
            options+=("Microsoft Edge: Remove settings")
        fi
        # Firefox without settings applied
        if [ "$OS" = "Darwin" ]; then
            options+=("Mozilla Firefox: Update settings")
        elif [ "$OS" = "Linux" ] && [ -x "$(command -v firefox)" ]; then
            options+=("Mozilla Firefox: Update settings")
        fi
        # Firefox with settings already applied
        if [ "$OS" = "Darwin" ]; then
            options+=("Mozilla Firefox: Remove settings")
        elif [ "$OS" = "Linux" ] && [ -e "/etc/firefox/policies/policies.json" ]; then
            options+=("Mozilla Firefox: Remove settings")
        fi
        # Firefox Flatpak
        if [ "$OS" = "Linux" ] && [ -x "$(command -v flatpak)" ] && flatpak list | grep -q "org.mozilla.firefox"; then
            options+=("Firefox Flatpak: Update settings")
            options+=("Firefox Flatpak: Remove settings")
        fi
        # Brave without settings applied
        if [ "$OS" = "Darwin" ]; then
            options+=("Brave: Update settings")
        elif [ "$OS" = "Linux" ] && [ -x "$(command -v brave-browser)" ]; then
            options+=("Brave: Update settings")
        fi
        # Brave with settings already applied
        if [ "$OS" = "Darwin" ]; then
            options+=("Brave: Remove settings")
        elif [ "$OS" = "Linux" ] && [ -e "/etc/brave/policies/managed/managed_policies.json" ]; then
            options+=("Brave: Remove settings")
        fi
        # Add exit option
        options+=("Exit")
        # Show main menu
        _show_header
        echo -e "Select an option by typing the number, then pressing Return/Enter on your keyboard to confirm.\n\nYou will need to restart your browser for changes to take effect.\n"
        # Detect Ctrl+D, which ends the select loop without running anything
        eof=1
        select choice in "${options[@]}"; do
            eof=0
            if [ "$choice" = "Google Chrome: Update settings" ]; then
                _install_chrome
            elif [ "$choice" = "Google Chrome: Remove settings" ]; then
                _uninstall_chrome
            elif [ "$choice" = "Chromium: Update settings" ]; then
                _install_chromium
            elif [ "$choice" = "Chromium: Remove settings" ]; then
                _uninstall_chromium
            elif [ "$choice" = "Chromium Flatpak: Update settings" ]; then
                _install_chromium_flatpak
            elif [ "$choice" = "Chromium Flatpak: Remove settings" ]; then
                _uninstall_chromium_flatpak
            elif [ "$choice" = "Microsoft Edge: Update settings" ]; then
                _install_edge
            elif [ "$choice" = "Microsoft Edge: Remove settings" ]; then
                _uninstall_edge
            elif [ "$choice" = "Mozilla Firefox: Update settings" ]; then
                _install_firefox
            elif [ "$choice" = "Mozilla Firefox: Remove settings" ]; then
                _uninstall_firefox
            elif [ "$choice" = "Firefox Flatpak: Update settings" ]; then
                _install_firefox_flatpak
            elif [ "$choice" = "Firefox Flatpak: Remove settings" ]; then
                _uninstall_firefox_flatpak
            elif [ "$choice" = "Brave: Update settings" ]; then
                _install_brave
            elif [ "$choice" = "Brave: Remove settings" ]; then
                _uninstall_brave
            elif [ "$choice" = "Exit" ]; then
                exit 0
            else
                read -p "Invalid option. Press Enter/Return to continue."
            fi
            # Leave the select loop so the menu is drawn again with fresh options
            break
        done
        if [ "$eof" = 1 ]; then
            echo ""
            exit 0
        fi
    done
}

# scripts/test_main_sh.sh sources this file to exercise the download checks
# directly. Everything else runs the menu as usual.
if [ "${JTB_SOURCE_ONLY:-}" != "1" ]; then
    _main
fi
