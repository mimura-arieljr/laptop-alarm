#!/bin/bash
# Spike: launch the root engine through the macOS administrator prompt.
# - Run it yourself; the dialog needs your password.
# - SPIKE_DRY_RUN=1 prints the osascript command instead of running it.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$REPO/build/laptop-alarm"
LOG="/tmp/laptop-alarm-spike.log"
USER_NAME="${USER:-$(id -un)}"

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
