#!/bin/bash
# Spike: launch the root engine through the macOS administrator prompt.
# - Run it yourself; the dialog needs your password.
# - SPIKE_DRY_RUN=1 prints the osascript command instead of running it.
set -euo pipefail

die() { echo "spike-elevation: $*" >&2; exit 1; }

# Args: effective uid, resolved user name.
check_not_root() {
  [[ "$1" -ne 0 ]] ||
    die "do NOT run this script with sudo. Run it as your own user; the macOS administrator dialog asks for your password itself."
  [[ -n "$2" && "$2" != "root" ]] ||
    die "resolved user is '$2', expected your normal account. Run as your own user, not root."
}

USER_NAME="${USER:-$(id -un)}"
# Test hook, only honored in dry-run mode.
[[ "${SPIKE_DRY_RUN:-}" == "1" && -n "${SPIKE_FORCE_USER:-}" ]] && USER_NAME="$SPIKE_FORCE_USER"
check_not_root "$EUID" "$USER_NAME"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$REPO/build/laptop-alarm"
LOG="/tmp/laptop-alarm-spike.log"

# Wrap in single quotes for the shell; escape embedded single quotes.
sh_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# Escape backslashes and double quotes for an AppleScript string literal.
as_escape() {
  local s="${1//\\/\\\\}"
  printf '%s' "${s//\"/\\\"}"
}

cd "$REPO"
./build.sh engine

SHELL_CMD="$(sh_quote "$ENGINE") arm --user $(sh_quote "$USER_NAME") --countdown 5 --volume 0.2 > $(sh_quote "$LOG") 2>&1 &"
APPLE_SCRIPT="do shell script \"$(as_escape "$SHELL_CMD")\" with administrator privileges"

if [[ "${SPIKE_DRY_RUN:-}" == "1" ]]; then
  echo "DRY RUN, would run:"
  echo "osascript -e $(sh_quote "$APPLE_SCRIPT")"
  exit 0
fi

osascript -e "$APPLE_SCRIPT"

cat <<MSG

Engine launched. Log: $LOG
  tail -f $LOG

Checks (report pass or fail for each):
  1. This script returned promptly and the engine keeps running (pgrep laptop-alarm).
  2. The log shows the accelerometer woken and the lid angle sensor opened.
  3. After about 15 s, tilt the laptop: the siren plays, the volume is forced
     to 0.2, and the voice is spoken (not silent).
  4. A push arrives on the phone.
  5. sudo pkill -TERM laptop-alarm restores volume and sleep
     (pmset -g | grep SleepDisabled shows 0).

Stop the engine:  sudo pkill -TERM laptop-alarm
Recovery:         sudo pmset -a disablesleep 0
MSG
