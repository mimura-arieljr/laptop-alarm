# Laptop Alarm

A macOS menu bar app that sounds a loud siren, speaks a warning, and sends a push notification to your phone when someone lifts, moves or tampers with your MacBook while you have left it unattended.

> **Status: early.** Built and tested by one person on one Mac (a MacBook Air M5 running macOS 26.7.1). It is a deterrent, not real protection. Read [Limitations](#limitations) before you rely on it.

## What it does

You click **Arm** in the menu bar, type your Mac password once, and walk away. After a 10 second countdown and a 1 second calibration, the alarm is armed. It then watches for:

- **Motion:** the laptop is tilted more than 2 degrees from where it rested, or knocked hard enough to change the total force on it.
- **Lid angle:** the lid hinge moves more than 3 degrees.
- **Lid closed:** someone shuts the lid.
- **Charger unplugged:** only if you armed it while plugged in.

When any of these happens, the siren sweeps loudly, a voice says "This laptop is being stolen", and your phone gets a push notification with the reason. The siren keeps going until someone types your Mac password to disarm it. The volume is forced to maximum and unmuted for as long as the alarm sounds.

While armed, the app also stops the Mac from sleeping when the lid closes, so the alarm stays alive. Disarming restores everything.

## Why it exists

macOS has no built-in motion alarm. Find My helps you after a theft, and only once the thief goes online. This project tries to cover the moment before that: the few seconds when someone picks up your laptop from a cafe table, a desk or a library seat, and a loud alarm and a push to your phone might make them put it back.

It uses the motion sensor and lid angle sensor that Apple Silicon MacBooks already have, so it needs no extra hardware.

## Limitations

Please read these. Several are real gaps, not edge cases.

**Hardware and software**
- **Apple Silicon MacBooks only**, tested on **one** machine (MacBook Air M5, macOS 26.7.1). The app declares macOS 14 as the minimum, but nothing older than 26 has been tried.
- **The motion sensor is read through undocumented, reverse-engineered properties.** They worked on the one Mac tested. They may not work on other models or after a macOS update. If the motion sensor is not working, the app still arms, but shows an orange "degraded" state and only the lid and charger triggers are active. To find out which sensors your Mac exposes, build and run `tools/sensor_probe_v2.swift` (the build and run commands are in the comment at the top of the file) and compare its output with the sensor table in `CLAUDE.md`.

**What the alarm cannot do**
- **With the lid closed, the siren is inaudible.** It plays, but you will not hear it, even at full volume. It becomes audible when the lid opens. This is why the phone push exists: it is the only alert that works for a closed laptop in a bag.
- **A hard power-off defeats it.** Holding the power button shuts the Mac down and no software alarm survives that.
- **If the laptop is off, asleep without the alarm, or out of battery, it does nothing.**
- **It is a deterrent, not protection.** Use Find My and Activation Lock for recovery.
- **Bluetooth headphones can receive the siren instead of the speakers.** AirPods that are in range reconnect on their own and may take over the output. Disconnect them before you rely on the alarm.

**Phone alerts**
- Push uses the free [ntfy.sh](https://ntfy.sh) service. The topic name is the only secret protecting your channel, so the app generates a long random one. Anyone who learns it could read or fake your alerts.
- Messages go through ntfy.sh, and on iPhone possibly through Apple and Google push infrastructure. They contain only the reason (for example "lid closed"), never a location.
- The iPhone ntfy app is described by its own FAQ as basic. Test that pushes arrive reliably before you trust it.
- The Mac needs an internet connection to send the push.

**Security tradeoffs you are accepting**
- **Arming needs your Mac password every time.** The app starts a root process through the standard macOS administrator prompt. There is no background helper and no stored credential.
- **That root process runs from the app bundle, which you own.** A malicious program running as you could replace it before your next arming. This was accepted to avoid installing a privileged helper.
- **Only your Mac password disarms** once the alarm is armed. A wrong password is refused and repeated wrong attempts are slowed down. Cancel without a password only works during the countdown.

**Things that were not verified yet**
- Quitting and reopening the app while armed (it is meant to reconnect and show armed).
- What the app shows if the engine is killed with `kill -9`.
- Triggers tested one by one: tilt, knock and lid closed work. Lid angle, charger unplug, and a knock without any tilt are untested.
- Whether macOS shows a warning the first time you open the app you built yourself (it should not, because it was never downloaded, but this was not checked).

## Setup

### What you need

- A MacBook with an Apple Silicon chip.
- Apple's free command line developer tools, which include the Swift compiler. Check with `swiftc --version`. If it is missing, run `xcode-select --install` and follow the prompts.
- An iPhone or Android phone with the free [ntfy](https://ntfy.sh) app, if you want push alerts.
- Your Mac account must be an administrator, because arming asks for your password.

Nothing here costs money. There is no paid Apple Developer account involved, because you build the app yourself on your own Mac.

### 1. Get the code and build it

```bash
git clone https://github.com/<your-account>/laptop-alarm.git
cd laptop-alarm
./build.sh test        # optional: runs the unit tests, should end with "All tests passed"
./build.sh app         # builds build/LaptopAlarm.app
```

> **Do not run these commands with `sudo`.** The app asks for your password by itself when you arm it. Building as root leaves files you cannot overwrite later.

One of the tests uses the macOS `say` command, which needs a normal logged-in desktop session. It will fail if you run the tests over SSH.

### 2. Install and open it

```bash
./build.sh install     # copies the app to /Applications
open /Applications/LaptopAlarm.app
```

You can also skip the install and run `open build/LaptopAlarm.app` to try it from the build folder.

A **lock icon** appears in the menu bar. There is no Dock icon. If you want it to start automatically, add `LaptopAlarm` in System Settings, General, Login Items.

### 3. Set up phone alerts (optional, recommended)

1. Install the **ntfy** app on your phone.
2. In the menu bar, click the lock icon and choose **Phone alerts: not set up**. A small "Phone alerts" window opens.
3. Click **Create topic** to generate your private topic, then **Copy**.
4. In the ntfy app, tap **+**, paste the topic name, and keep the default server (`ntfy.sh`).
5. Back in the Mac window, click **Send test**. Your phone should show "Test alert from your Mac."

The menu now reads "Phone alerts: set up". If you skip this step the alarm still works, and the menu shows that phone alerts are not set up.

### 4. Try it safely

Do the first test at low volume, near you, with your AirPods and other Bluetooth audio disconnected.

1. Click the lock icon, open **Siren volume**, and choose **Low**.
2. Leave **Sensitivity** at **Normal** (2 degrees tilt, 0.09 g knock).
3. Choose **Arm**. A macOS password dialog appears. Type your Mac password.
4. The menu shows a countdown. **Cancel** is available during the countdown and the following calibration, and needs no password.
5. Keep the laptop still until the icon turns **red** (armed).
6. Tilt the laptop. You should hear the siren and the spoken warning, and your phone should get a push.
7. Click the lock icon and choose **Disarm...**. Type your Mac password. The siren stops and your volume and sleep settings come back.

When that works, set **Siren volume** to **Full** for real use.

### Using it for real

1. Put the laptop where you will leave it, plugged in if you want the charger trigger.
2. Arm it, lock the screen (Control, Command, Q), and walk away. The sensors keep working while the screen is locked.
3. When you are back, unlock the screen, then choose **Disarm...** from the menu.

The menu cannot be quit while the alarm is armed.

## Settings

| Menu | Options | What it changes |
|---|---|---|
| Sensitivity | Low, Normal, High | How much tilt and knock force sets it off. Normal is 2 degrees and 0.09 g. Low is 5 degrees and 0.15 g. High is 1 degree and 0.06 g. |
| Siren volume | Low, Medium, Full | The volume the alarm forces: 25%, 50% or 100%. Default is Full. |

Changes apply the next time you arm. Your choices are remembered.

## If something goes wrong

The alarm runs as a separate process so it survives the app closing. If the app shows a "lost contact" message, or the Mac seems stuck awake and armed, recover in this order. Run the first two in a normal Terminal window.

```bash
./build/laptop-alarm status           # is an alarm running, and in what state?
./build/laptop-alarm disarm           # disarm it; asks for your Mac password (no sudo)
sudo pkill -TERM laptop-alarm         # stop a stuck alarm and run its cleanup
sudo pmset -a disablesleep 0          # restore sleep if it was left disabled
```

The password prompt only works in a real Terminal window, not inside an editor's command box or a script.

If the Mac still behaves oddly after a `kill -9` or a crash, restart it. That also resets the motion sensor.

## Uninstall

```bash
rm -rf /Applications/LaptopAlarm.app
rm -f ~/.laptop-alarm-ntfy-topic       # your phone-alert topic
```

Then remove the topic from the ntfy app.

## How it works

This is the short version. [docs/TECHNICAL.md](docs/TECHNICAL.md) has the full technical documentation, with diagrams: the privilege model, the arming sequence, sensing and triggers, the control protocol, failure modes and known gaps.

- **The engine** (`Sources/Engine`) is a command line program that runs as root. It wakes the accelerometer, reads the lid angle sensor, plays the siren, blocks sleep, and sends the push.
- **The menu bar app** (`Sources/App`) runs as you. When you arm, it starts the engine through the macOS administrator prompt, and talks to it over a private socket at `/var/run/laptop-alarm.sock` that only you can use.
- **The voice** is rendered by the app as you, because macOS `say` is silent when started through the administrator prompt. The engine plays the file.
- Shared code lives in `Sources/Shared`, the testable app logic in `Sources/AppLogic`, and tests in `tests/`.

You can also drive the engine directly from a terminal: `sudo ./build/laptop-alarm arm`. See `./build/laptop-alarm` for usage, and build it first with `./build.sh engine`.

## Developing

```bash
./build.sh test            # unit tests
./build.sh bundle-check    # checks the built .app (run ./build.sh app first)
./build.sh engine          # just the engine, at build/laptop-alarm
./build.sh clean
```

The app icon is drawn by `tools/make-icon.swift` during `./build.sh app`, so there is no image file to edit. Change the drawing in that script to change the icon.

`CLAUDE.md` holds detailed project notes: sensor findings, the control protocol, and known gotchas.
