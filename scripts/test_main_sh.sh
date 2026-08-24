#!/bin/bash
#
# Runtime tests for the download checks in main.sh.
#
# main.sh installs browser policies by downloading them over the network and
# writing them into system directories as root. A captive portal, a proxy notice
# or an error page served with a 200 status would otherwise be installed as
# policy, and an interrupted download would overwrite a working configuration
# with a broken one. main.sh guards against both, but "bash -n" and ShellCheck
# only prove the file parses, so those guards were never actually exercised.
#
# This serves fixtures over a local HTTP server and checks that main.sh accepts
# what it should and rejects what it should.
#
# Run it with: scripts/test_main_sh.sh
#
# The end-to-end part writes to the real policy directories under /etc, so it
# only runs when JTB_ALLOW_SYSTEM_TEST=1 is set. The GitHub Action sets it,
# because the runner is thrown away afterwards.

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
FAILURES=0
SERVER_PID=""
WORK_DIR=""

_pass() {
    echo "  ok    $1"
}

_fail() {
    echo "  FAIL  $1"
    FAILURES=$((FAILURES + 1))
}

_cleanup() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null
        wait "$SERVER_PID" 2>/dev/null
    fi
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
}
trap _cleanup EXIT

# Build the files the fake server hands out. Each top-level directory is a
# separate base URL, laid out the way the real repository is, so main.sh can be
# pointed at it with its existing base URL argument.
_build_fixtures() {
    WORK_DIR=$(mktemp -d) || { echo "Could not create a temporary directory."; exit 1; }
    SERVE_DIR="$WORK_DIR/serve"
    mkdir -p "$SERVE_DIR/good/chrome" "$SERVE_DIR/good/firefox" \
             "$SERVE_DIR/html/chrome" "$SERVE_DIR/truncated/chrome" \
             "$SERVE_DIR/empty/chrome" "$SERVE_DIR/notjson/chrome"

    # The real policy files, so a passing test means the actual configuration
    # this repository ships is accepted
    cp "$REPO_ROOT/chrome/managed_policies.json" "$SERVE_DIR/good/chrome/managed_policies.json"
    cp "$REPO_ROOT/chrome/chrome.mobileconfig" "$SERVE_DIR/good/chrome/chrome.mobileconfig"
    cp "$REPO_ROOT/firefox/policies.json" "$SERVE_DIR/good/firefox/policies.json"

    # An error page or portal notice served with a 200 status
    cat > "$SERVE_DIR/html/chrome/managed_policies.json" <<'HTML'
<!DOCTYPE html>
<html><head><title>Sign in to the network</title></head>
<body><p>Please sign in to continue.</p></body></html>
HTML
    cp "$SERVE_DIR/html/chrome/managed_policies.json" "$SERVE_DIR/html/chrome/chrome.mobileconfig"

    # A download that was cut off part way through: it starts like JSON, so the
    # cheap first-character check passes and only a real parse catches it
    printf '{\n  "AIModeSettings": 1,\n  "BrowserSignin"' \
        > "$SERVE_DIR/truncated/chrome/managed_policies.json"

    # A download that produced nothing at all
    : > "$SERVE_DIR/empty/chrome/managed_policies.json"

    # Valid, parseable, and still not a policy file
    printf '[1, 2, 3]\n' > "$SERVE_DIR/notjson/chrome/managed_policies.json"
}

_start_server() {
    local port
    port=$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()') || { echo "Could not pick a port."; exit 1; }
    ( cd "$SERVE_DIR" && exec python3 -m http.server "$port" --bind 127.0.0.1 ) >/dev/null 2>&1 &
    SERVER_PID=$!
    BASE_URL="http://127.0.0.1:$port"
    # --retry-connrefused waits for the server to come up without a fixed sleep
    curl -s --retry 20 --retry-connrefused --retry-delay 1 -o /dev/null \
        "$BASE_URL/good/chrome/managed_policies.json" || {
        echo "The fixture server did not start."
        exit 1
    }
}

# Check that _fetch_verified accepts or rejects a URL as expected.
# Usage: _check_fetch <accept|reject> <description> <url> <json|plist>
_check_fetch() {
    local expected="$1"
    local description="$2"
    local url="$3"
    local kind="$4"
    local out
    local rc
    out=$(mktemp) || { _fail "$description (no temporary file)"; return; }
    _fetch_verified "$url" "$kind" "$out" >/dev/null 2>&1
    rc=$?
    rm -f "$out"
    if [ "$expected" = "accept" ] && [ "$rc" -eq 0 ]; then
        _pass "$description"
    elif [ "$expected" = "reject" ] && [ "$rc" -ne 0 ]; then
        _pass "$description"
    elif [ "$expected" = "accept" ]; then
        _fail "$description (expected it to be accepted, it was rejected)"
    else
        _fail "$description (expected it to be rejected, it was accepted)"
    fi
}

_test_download_checks() {
    echo "Download checks:"
    _check_fetch accept "a real policy file is accepted" \
        "$BASE_URL/good/chrome/managed_policies.json" json
    _check_fetch accept "a real Firefox policy file is accepted" \
        "$BASE_URL/good/firefox/policies.json" json
    _check_fetch accept "a real configuration profile is accepted" \
        "$BASE_URL/good/chrome/chrome.mobileconfig" plist

    _check_fetch reject "an HTML page served as policy is rejected" \
        "$BASE_URL/html/chrome/managed_policies.json" json
    _check_fetch reject "an HTML page served as a profile is rejected" \
        "$BASE_URL/html/chrome/chrome.mobileconfig" plist
    _check_fetch reject "a download cut off part way through is rejected" \
        "$BASE_URL/truncated/chrome/managed_policies.json" json
    _check_fetch reject "an empty download is rejected" \
        "$BASE_URL/empty/chrome/managed_policies.json" json
    _check_fetch reject "JSON that is not an object is rejected" \
        "$BASE_URL/notjson/chrome/managed_policies.json" json
    _check_fetch reject "a missing file is rejected" \
        "$BASE_URL/good/chrome/does_not_exist.json" json
    _check_fetch reject "a policy file served as a profile is rejected" \
        "$BASE_URL/good/chrome/managed_policies.json" plist
}

_test_no_partial_write() {
    echo "Failed downloads leave the target alone:"
    local target_dir="$WORK_DIR/target"
    local target="$target_dir/managed_policies.json"
    mkdir -p "$target_dir"
    printf '{"AlreadyInstalled": true}\n' > "$target"

    _install_json "$BASE_URL/html/chrome/managed_policies.json" \
        "$target_dir" "managed_policies.json" >/dev/null 2>&1
    if grep -q "AlreadyInstalled" "$target"; then
        _pass "an HTML response does not overwrite an installed policy file"
    else
        _fail "an HTML response overwrote an installed policy file"
    fi

    _install_json "$BASE_URL/truncated/chrome/managed_policies.json" \
        "$target_dir" "managed_policies.json" >/dev/null 2>&1
    if grep -q "AlreadyInstalled" "$target"; then
        _pass "a truncated download does not overwrite an installed policy file"
    else
        _fail "a truncated download overwrote an installed policy file"
    fi

    _install_json "$BASE_URL/good/chrome/managed_policies.json" \
        "$target_dir" "managed_policies.json" >/dev/null 2>&1
    if cmp -s "$target" "$REPO_ROOT/chrome/managed_policies.json"; then
        _pass "a good download does install"
    else
        _fail "a good download did not install"
    fi
}

# Find the number the menu is currently giving an option. The menu is rebuilt
# every pass, so the numbers move as configurations are installed and removed.
# Usage: _menu_number <base url> <option label>
_menu_number() {
    local base="$1"
    local label="$2"
    COLUMNS=1 PATH="$STUB_BIN:$PATH" "$REPO_ROOT/main.sh" "$base" </dev/null 2>&1 \
        | tr -d '\r' \
        | sed -n "s/^ *\([0-9][0-9]*\)) *$label\$/\1/p" \
        | head -1
}

# Run the menu once, choosing one option, and print everything it wrote.
# Usage: _run_menu <base url> <option label>
_run_menu() {
    local base="$1"
    local label="$2"
    local number
    number=$(_menu_number "$base" "$label")
    if [ -z "$number" ]; then
        echo "MENU_OPTION_NOT_FOUND"
        return
    fi
    # The trailing blank line answers the "press Enter to continue" prompt, then
    # the menu is drawn again and reaches the end of the input, which exits
    printf '%s\n\n' "$number" \
        | COLUMNS=1 PATH="$STUB_BIN:$PATH" "$REPO_ROOT/main.sh" "$base" 2>&1
}

_test_end_to_end() {
    echo "Installing through the menu:"
    local live="/etc/opt/chrome/policies/managed/managed_policies.json"
    if [ -e "$live" ]; then
        echo "  skip  $live already exists, refusing to touch it"
        return
    fi

    # main.sh only offers Chrome when a Chrome binary is on the PATH
    STUB_BIN="$WORK_DIR/bin"
    mkdir -p "$STUB_BIN"
    printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/google-chrome"
    chmod 755 "$STUB_BIN/google-chrome"

    _run_menu "$BASE_URL/good" "Google Chrome: Update settings" >/dev/null 2>&1
    if cmp -s "$live" "$REPO_ROOT/chrome/managed_policies.json"; then
        _pass "a good policy file installs to $live"
    else
        _fail "a good policy file did not install to $live"
        return
    fi

    local output
    output=$(_run_menu "$BASE_URL/html" "Google Chrome: Update settings" 2>&1)
    if printf '%s' "$output" | grep -q "not a JSON configuration file"; then
        _pass "an HTML response is reported to the user"
    else
        _fail "an HTML response was not reported to the user"
    fi
    if cmp -s "$live" "$REPO_ROOT/chrome/managed_policies.json"; then
        _pass "an HTML response leaves the installed policy file in place"
    else
        _fail "an HTML response replaced the installed policy file"
    fi

    output=$(_run_menu "$BASE_URL/truncated" "Google Chrome: Update settings" 2>&1)
    if printf '%s' "$output" | grep -q "not valid JSON"; then
        _pass "a truncated download is reported to the user"
    else
        _fail "a truncated download was not reported to the user"
    fi
    if cmp -s "$live" "$REPO_ROOT/chrome/managed_policies.json"; then
        _pass "a truncated download leaves the installed policy file in place"
    else
        _fail "a truncated download replaced the installed policy file"
    fi

    _run_menu "$BASE_URL/good" "Google Chrome: Remove settings" >/dev/null 2>&1
    if [ -e "$live" ]; then
        _fail "the menu did not remove $live"
    else
        _pass "the menu removes $live again"
    fi
}

_build_fixtures
_start_server

# Load main.sh without running its menu, so the download helpers can be called
# directly. The base URL argument is required, and is not used by these tests.
# This is deliberately not exported: the menu tests below run main.sh as a
# separate process and need it to draw its menu as usual.
# ShellCheck cannot see that main.sh reads this once it is sourced below
# shellcheck disable=SC2034
JTB_SOURCE_ONLY=1
# shellcheck source=../main.sh
. "$REPO_ROOT/main.sh" "$BASE_URL/good"
unset JTB_SOURCE_ONLY

_test_download_checks
_test_no_partial_write

if [ "${JTB_ALLOW_SYSTEM_TEST:-}" = "1" ]; then
    _test_end_to_end
else
    echo "Installing through the menu:"
    echo "  skip  set JTB_ALLOW_SYSTEM_TEST=1 to run tests that write under /etc"
fi

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "All checks passed."
    exit 0
fi
echo "$FAILURES check(s) failed."
exit 1
