# Laptop Alarm (macOS anti-theft)

## Goal
A tool that sounds a loud alarm when someone lifts or tampers with my MacBook while I leave it unattended.

## Hardware
MacBook Air M5, 32 GB RAM, Apple Silicon. Recent macOS.

## Files
Build with `./build.sh engine | app | app-dev | install | test | bundle-check | clean`. Output goes to `build/`.
- `Sources/Engine/`: the root alarm engine and CLI (`build/laptop-alarm`, from `./build.sh engine`).
  Commands: `sudo ./build/laptop-alarm monitor | test-siren | push-setup | arm` with flags `--tilt --shock --lid --countdown --volume --user --headless --voice-file`.
  Plus `./build/laptop-alarm status | disarm`, which need no sudo.
- `Sources/App/`, `Sources/AppLogic/`: the menu bar app. `AppLogic` is the testable part (state, settings, elevation command building).
- `Sources/Shared/`: code shared by the engine, the app and tests (control protocol and socket, `run`, invoking-user resolution, ntfy push, voice file, attempt limiter).
- `tests/`: plain test runner (`./build.sh test`, output `build/tests`). `tests/bundle-check.sh` (`./build.sh bundle-check`) checks the built `.app` after `./build.sh app`.
- `./build.sh app` builds `build/LaptopAlarm.app` (engine inside at `Contents/Resources/laptop-alarm`, ad-hoc signed). `./build.sh install` copies it to `/Applications` (override with `INSTALL_DIR`). `app-dev` builds only the bare app binary.
- `scripts/spike-elevation.sh`: throwaway check of the administrator-prompt launch.
- `sensor_probe.swift`, `sensor_probe_v2.swift`: one-time discovery probes. They are done and only kept for reference.

## Sensor findings (from probe runs on this machine)
All sensors are HID devices on the SPU transport, vendor 0x05AC, product ID 0x8104 where shown.

| Usage page / usage | What it is | Confidence | Notes |
|---|---|---|---|
| 0x0020 / 0x008A | Lid angle sensor | High | Feature report ID 1, byte 1 (low) + byte 2 (high) = degrees. Polling works without root. Pushed input reports are about 1 Hz. |
| 0xFF00 / 0x0003 | Accelerometer | High (inferred) | Silent until woken. 22-byte report, bytes 6-9 / 10-13 / 14-17 = X / Y / Z as int32 little-endian, 65536 = 1 g. Flat at rest: Z about -1.005 g. |
| 0xFF00 / 0x0009 | Probably a gyroscope | Medium | Same 22-byte layout. Near zero at rest. Silent until woken. |
| 0xFF00 / 0x0004 | Ambient light sensor | High | About 10 Hz. Bytes 40-43 are a float32 lux value. Do NOT use as a trigger. |
| 0xFF00 / 0x0005, 0xFF0C / 0x0001 | Unknown | n/a | Ignore. |

Waking the accelerometer needs root. Write `SensorPropertyReportingState=1`, `SensorPropertyPowerState=1`, and `ReportInterval=<microseconds>` to the `AppleSPUHIDDriver` services through `IORegistryEntrySetCFProperty`. This worked on all 8 drivers. These property names are undocumented and came from hobbyist reverse-engineering.

Public APIs also confirmed working: the power source (`IOPSGetProvidingPowerSourceType`) and `AppleClamshellState` on `IOPMrootDomain`.

Lesson learned: never compare individual bytes for signed values. Noise around zero flips bytes between 0x00 and 0xFF. Decode full int32 values instead.

## Engine design
- Arm flow: countdown, then 1 s calibration (baseline gravity vector, lid angle, AC state), then armed.
- Triggers: tilt > 2° from baseline, or a change in |a| > 0.09 g (measured peaks: idle 0.2° / 0.001 g, table bump 0.6° / 0.066 g, gentle lift 7.3° / 0.131 g; low-pass filtered with EMA alpha 0.3, must hold for 5 samples at 50 Hz); lid angle change > 3° on 2 consecutive 10 Hz polls; lid closed; charger unplugged (only if armed while on AC).
- When triggered: siren latches on (a square wave generated in memory, sweeping 700-1600 Hz, then a spoken "This laptop is being stolen" from macOS `say`, looped with AVAudioPlayer). The sound is built when the alarm starts, so firing never waits on `say`. If `say` fails, it falls back to the siren alone. Volume is forced to max and unmuted 10 times per second through CoreAudio / AudioHardwareService.
- Push: on trigger, one ntfy.sh message (title "Laptop alarm triggered", body = the reason) is sent from a background thread, 5 tries, 3 s apart, so it never delays the siren.
  - `sudo ./build/laptop-alarm push-setup` creates a random topic in `~/.laptop-alarm-ntfy-topic` (mode 0600) and sends a test push. Subscribe to that topic in the ntfy iPhone app.
  - The topic name is the only secret. Messages carry no location. Arming prints a warning if no topic is set up.
- While armed: `pmset -a disablesleep 1`, so closing the lid cannot sleep the Mac.
- Disarm: type the macOS password in Terminal. It is verified with OpenDirectory against the invoking user (the `--user` flag, else `SUDO_USER`). Ctrl+C is ignored while armed. SIGTERM and SIGHUP clean up and exit.
- Cleanup restores volume, sleep setting, SPU driver properties, and the terminal's termios. If an original SPU value was unreadable, the accelerometer is put back to sleep.

## Menu bar app
- A lock icon in the menu bar (`LSUIElement`, no Dock icon, macOS 14+). Menu: status lines, Arm / Cancel / Disarm..., Sensitivity (low/normal/high), Siren volume (low/medium/full), Phone alerts window, Quit (disabled while armed). The two choices persist across launches.
- Arm starts the engine through the macOS administrator prompt every time (`osascript ... with administrator privileges`), as `arm --headless --user <you> ...`. No stored credentials, no helper tool. Cancelling the prompt returns to disarmed.
- The app renders the voice file itself, as the user, and hands it to the engine with `--voice-file`. `say` is silent under the admin-prompt launch, so the engine cannot render it.
- The app finds the engine at `Bundle.main.resourceURL/laptop-alarm`.
- Disarm in the app asks for the macOS password, which the engine verifies. Quitting and reopening while armed reconnects and shows armed.

## Control socket
- `/var/run/laptop-alarm.sock`, created by the headless engine, owned by the user (the invoking user), mode 0600. Line based, one command per line.
- Client commands: `STATUS`, `CANCEL`, `DISARM <base64 password>`.
- Engine replies: `STATE disarmed|countdown N|calibrating|armed|degraded <why>|triggered <why>`, `WARN <text>`, `OK`, `ERR <code>`. The engine sends the current state and warnings on connect, and pushes state changes to connected clients.
- Failed password attempts are rate limited in the engine.

## Status / next steps
The engine, app, socket and bundle are built and unit-tested. Still to do is the owner's end-to-end run on `build/LaptopAlarm.app`: arm and cancel, the cancelled admin prompt, trigger with siren + voice + phone push, wrong and right disarm password, quit and reopen while armed, `kill -9` of the engine (the app shows the recovery message), and persistence of the Sensitivity and Siren choices.

## Known gotchas
- Bluetooth headphones receive the siren instead of the built-in speakers. AirPods in range keep auto-reconnecting and flip the default output.
- `say` run directly as root, or under the admin-prompt launch, writes silence with no error. From the app the voice file is rendered as the user and passed in with `--voice-file`. From a terminal the engine runs `sudo -u <invoking user> say` (the `--user` flag, else `SUDO_USER`), in a private temp dir owned by that user.
- With the lid closed the siren plays but is inaudible, even at 100% volume (observed). It becomes audible when the lid opens. Accepted limit, so closed-lid theft relies on the phone push.
- A crash or `kill -9` skips cleanup. Recovery, in order:
  - `./build/laptop-alarm status` shows whether an engine is running. `./build/laptop-alarm disarm` disarms it (no sudo, but the password prompt needs a real Terminal).
  - `sudo pkill -TERM laptop-alarm` stops a stuck engine and runs its cleanup.
  - `sudo pmset -a disablesleep 0`, then reboot to reset the sensor.
- Accepted risk: the root engine runs from a user-writable app bundle. A process running as my user could swap the engine binary before the next admin prompt. I accepted this to avoid a privileged helper.
- Holding the power button for a hard shutdown defeats any software alarm. This is a deterrent, not real protection. Use Find My and Activation Lock for recovery.
- `sudo` commands need my password interactively. Ask me to run them myself rather than trying to run them for me.

## Deferred on purpose
Disarming by Touch ID or screen unlock, forcing the built-in speakers, and a photo of whoever triggered the alarm.

## How I like to work
Be direct and skip preamble. Disagree when something seems off. Surface risks and tradeoffs on nontrivial choices, and say which alternatives you didn't pick and why. Separate what you know, what you infer, and what you guess. Fix problems at the root, not with one-off patches. Never use em dashes.
