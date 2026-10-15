// laptop-alarm.swift  (v1)
// Anti-theft alarm for Apple Silicon MacBooks (built against an M5 Air).
//
// Build:   swiftc -O laptop-alarm.swift -o laptop-alarm
//
// Commands:
//   sudo ./laptop-alarm monitor       Live sensor readout for verifying and tuning. Ctrl+C to exit.
//   sudo ./laptop-alarm test-siren    Plays the siren once at your CURRENT volume.
//   sudo ./laptop-alarm push-setup    Creates the private ntfy topic and sends a test push to your phone.
//   sudo ./laptop-alarm arm           Countdown, calibrate, then arm. Disarm by typing your macOS password.
//
// Tuning flags (arm and monitor):
//   --tilt <degrees>   tilt from resting position that triggers      (default 2)
//   --shock <g>        change in total force that triggers           (default 0.09)
//   --lid <degrees>    lid hinge movement that triggers              (default 3)
//   --countdown <s>    seconds before arming                         (default 10)
//   --volume <0-1>     system volume forced when the alarm fires     (default 1, use 0.1 to test)
//
// Triggers while armed: motion (tilt or lift), lid angle change, lid closed,
// charger unplugged (only if armed while plugged in).
//
// Side effects while armed (all restored on disarm, Ctrl+C before arming, SIGTERM or SIGHUP):
//   - Wakes the SPU accelerometer (undocumented driver properties)
//   - `pmset -a disablesleep 1` so closing the lid cannot sleep the Mac
//   - Forces output volume to max and unmuted while the siren sounds
// A `kill -9` or a crash skips the restore. If that happens, run:
//   sudo pmset -a disablesleep 0     and reboot to reset the sensor.

import Foundation
import IOKit
import IOKit.hid
import IOKit.ps
import AVFoundation
import CoreAudio
import AudioToolbox
import OpenDirectory

// MARK: - Config

struct Config {
    var tiltDegrees = 2.0             // measured: idle 0.2, table bump 0.6, gentle lift 7.3
    var shockG = 0.09                 // measured: idle 0.001, table bump 0.066, gentle lift 0.131
    var lidDegrees = 3.0
    var countdown = 10
    var sirenVolume: Float32 = 1.0    // system volume forced while the alarm sounds
    var sustainSamples = 5            // consecutive over-threshold samples (5 at 50 Hz = 100 ms)
    var reportIntervalMicros = 20_000 // 50 Hz
}

// MARK: - Utilities

func note(_ s: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    print("[\(f.string(from: Date()))] \(s)")
    fflush(stdout)
}

func fail(_ s: String) -> Never {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    exit(1)
}

/// The human account behind sudo. Set once at startup, before anything reads it.
var invokingUser: String?

func length(_ v: SIMD3<Double>) -> Double { (v * v).sum().squareRoot() }

func angleDegrees(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    let la = length(a), lb = length(b)
    guard la > 0, lb > 0 else { return 0 }
    let c = max(-1, min(1, (a * b).sum() / (la * lb)))
    return acos(c) * 180 / .pi
}

var savedTermios = termios()
var haveTermios = false
func saveTerminal() { haveTermios = tcgetattr(STDIN_FILENO, &savedTermios) == 0 }
func restoreTerminal() { if haveTermios { tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios) } }

// MARK: - HID helpers

func hidInt(_ d: IOHIDDevice, _ k: String) -> Int {
    (IOHIDDeviceGetProperty(d, k as CFString) as? NSNumber)?.intValue ?? -1
}
func hidStr(_ d: IOHIDDevice, _ k: String) -> String {
    (IOHIDDeviceGetProperty(d, k as CFString) as? String) ?? ""
}

func findSPUDevice(page: Int, usage: Int) -> IOHIDDevice? {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(mgr, ["PrimaryUsagePage": page, "PrimaryUsage": usage] as CFDictionary)
    let devices = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? []
    return devices.first { hidStr($0, "Transport").uppercased().contains("SPU") }
}

func readInt32LE(_ p: UnsafeMutablePointer<UInt8>, _ o: Int) -> Double {
    let u = UInt32(p[o]) | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2]) << 16 | UInt32(p[o + 3]) << 24
    return Double(Int32(bitPattern: u))
}

// MARK: - SPU wake / restore

final class SPUWaker {
    private struct Saved { let service: io_service_t; let key: String; let value: CFTypeRef? }
    private var saved: [Saved] = []
    private var services: [io_service_t] = []
    private(set) var targeted = false

    private func search(_ s: io_service_t, _ key: String) -> Int? {
        let down = IOOptionBits(kIORegistryIterateRecursively)
        let up = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        for opts in [down, up] {
            if let v = IORegistryEntrySearchCFProperty(s, kIOServicePlane, key as CFString, kCFAllocatorDefault, opts) as? NSNumber {
                return v.intValue
            }
        }
        return nil
    }

    /// Wakes the accelerometer driver. Falls back to waking all SPU drivers if it can't be isolated.
    func wake(intervalMicros: Int) -> Int {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &it) == KERN_SUCCESS else { return 0 }
        var all: [io_service_t] = []
        var s = IOIteratorNext(it)
        while s != 0 { all.append(s); s = IOIteratorNext(it) }
        IOObjectRelease(it)

        let accel = all.filter { search($0, "PrimaryUsagePage") == 0xFF00 && search($0, "PrimaryUsage") == 0x0003 }
        targeted = !accel.isEmpty
        services = targeted ? accel : all
        for s in all where !services.contains(s) { IOObjectRelease(s) }

        let values: [(String, Int)] = [
            ("SensorPropertyReportingState", 1),
            ("SensorPropertyPowerState", 1),
            ("ReportInterval", intervalMicros),
        ]
        var woken = 0
        for s in services {
            var ok = true
            for (k, v) in values {
                let old = IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                saved.append(Saved(service: s, key: k, value: old))
                if IORegistryEntrySetCFProperty(s, k as CFString, NSNumber(value: v)) != KERN_SUCCESS { ok = false }
            }
            if ok { woken += 1 }
        }
        return woken
    }

    /// Restores previous values. If a value was unreadable and only the accelerometer was
    /// touched, it is put back to sleep (it was silent before waking). If all drivers were
    /// woken, unreadable values are left alone so ambient light and lid sensors keep working.
    func restore() {
        for e in saved {
            if let v = e.value {
                IORegistryEntrySetCFProperty(e.service, e.key as CFString, v)
            } else if targeted && e.key != "ReportInterval" {
                IORegistryEntrySetCFProperty(e.service, e.key as CFString, NSNumber(value: 0))
            }
        }
        services.forEach { IOObjectRelease($0) }
        services.removeAll()
        saved.removeAll()
    }
}

// MARK: - Sensors

final class Accelerometer {
    var onSample: ((SIMD3<Double>) -> Void)?
    private(set) var lastSample = Date.distantPast
    private var device: IOHIDDevice?
    private let size = 64
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

    func start(intervalMicros: Int) -> Bool {
        guard let d = findSPUDevice(page: 0xFF00, usage: 0x0003) else { return false }
        guard IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return false }
        _ = IOHIDDeviceSetProperty(d, "ReportInterval" as CFString, NSNumber(value: intervalMicros))
        IOHIDDeviceRegisterInputReportCallback(d, buffer, size, { ctx, _, _, _, _, report, length in
            guard let ctx, length >= 18 else { return }
            let me = Unmanaged<Accelerometer>.fromOpaque(ctx).takeUnretainedValue()
            // Bytes 6-17: X, Y, Z as signed 32-bit little-endian, 65536 = 1 g (inferred from probe data)
            let v = SIMD3(readInt32LE(report, 6), readInt32LE(report, 10), readInt32LE(report, 14)) / 65536.0
            me.lastSample = Date()
            me.onSample?(v)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        device = d
        return true
    }

    func stop() {
        guard let d = device else { return }
        IOHIDDeviceUnscheduleFromRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone))
        device = nil
    }
}

func openLidSensor() -> IOHIDDevice? {
    guard let d = findSPUDevice(page: 0x20, usage: 0x8A),
          IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return nil }
    return d
}

func readLidAngle(_ d: IOHIDDevice) -> Int? {
    var buf = [UInt8](repeating: 0, count: 64)
    var len = CFIndex(64)
    let r = buf.withUnsafeMutableBufferPointer {
        IOHIDDeviceGetReport(d, kIOHIDReportTypeFeature, 1, $0.baseAddress!, &len)
    }
    guard r == kIOReturnSuccess, len >= 3 else { return nil }
    return Int(buf[1]) | Int(buf[2]) << 8
}

func lidClosed() -> Bool? {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard root != 0 else { return nil }
    defer { IOObjectRelease(root) }
    return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? Bool
}

func onACPower() -> Bool {
    let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    return (IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String) == "AC Power"
}

// MARK: - Sleep control

func isSleepDisabled() -> Bool {
    run("/usr/bin/pmset", ["-g"]).split(separator: "\n").contains { line in
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        return parts.first == "SleepDisabled" && parts.last == "1"
    }
}
func setSleepDisabled(_ on: Bool) { run("/usr/bin/pmset", ["-a", "disablesleep", on ? "1" : "0"]) }

// MARK: - Audio

func defaultOutputDevice() -> AudioDeviceID? {
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    let r = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
    return r == noErr ? dev : nil
}

func volumeAddress() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                               mScope: kAudioDevicePropertyScopeOutput,
                               mElement: kAudioObjectPropertyElementMain)
}
func muteAddress() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                               mScope: kAudioDevicePropertyScopeOutput,
                               mElement: kAudioObjectPropertyElementMain)
}

func getVolume() -> (volume: Float32, muted: UInt32)? {
    guard let dev = defaultOutputDevice() else { return nil }
    var va = volumeAddress()
    var v: Float32 = 0
    var vs = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(dev, &va, 0, nil, &vs, &v) == noErr else { return nil }
    var ma = muteAddress()
    var m: UInt32 = 0
    var ms = UInt32(MemoryLayout<UInt32>.size)
    _ = AudioObjectGetPropertyData(dev, &ma, 0, nil, &ms, &m)
    return (v, m)
}

func setVolume(_ volume: Float32, muted: UInt32) {
    guard let dev = defaultOutputDevice() else { return }
    var ma = muteAddress()
    var m = muted
    _ = AudioObjectSetPropertyData(dev, &ma, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
    var va = volumeAddress()
    var v = volume
    _ = AudioObjectSetPropertyData(dev, &va, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
}

/// Spoken text from macOS `say` as mono Int16 samples, peak-normalized. Empty if `say` fails.
func makeVoiceSamples(_ text: String, rate: Int = 44_100) -> [Int16] {
    // Root's `say` writes silence, so run it as the sudo user in a private temp dir they own.
    let user = invokingUser
    let dir = "/tmp/laptop-alarm-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false,
                                             attributes: [.posixPermissions: 0o700])
    if let user { run("/usr/sbin/chown", [user, dir]) }
    let path = dir + "/voice.wav"
    let sayArgs = ["-o", path, "--file-format=WAVE", "--data-format=LEI16@\(rate)", text]
    let out = user.map { run("/usr/bin/sudo", ["-u", $0, "/usr/bin/say"] + sayArgs) }
        ?? run("/usr/bin/say", sayArgs)
    guard let d = FileManager.default.contents(atPath: path), d.count > 12 else {
        note("say wrote no file at \(path). Output: \(out.isEmpty ? "(none)" : out)")
        return []
    }
    var o = 12
    var seen: [String] = []
    while o + 8 <= d.count {
        let id = String(decoding: d[o..<o + 4], as: UTF8.self)
        seen.append(id)
        let size = Int(d[o + 4]) | Int(d[o + 5]) << 8 | Int(d[o + 6]) << 16 | Int(d[o + 7]) << 24
        if id == "data" {
            let end = min(d.count, o + 8 + size) - 1
            var s: [Int16] = []
            var i = o + 8
            while i < end {
                s.append(Int16(bitPattern: UInt16(d[i]) | UInt16(d[i + 1]) << 8))
                i += 2
            }
            let peak = s.map { abs(Int($0)) }.max() ?? 0
            guard peak > 0 else {
                note("say wrote silence (\(s.count) samples, file \(d.count) bytes). Output: \(out.isEmpty ? "(none)" : out)")
                return []
            }
            let gain = 0.9 * Double(Int16.max) / Double(peak)
            return s.map { Int16(Double($0) * gain) }
        }
        o += 8 + size + (size & 1)
    }
    note("say file has no data chunk (\(d.count) bytes, chunks: \(seen)). Output: \(out.isEmpty ? "(none)" : out)")
    return []
}

/// Siren sweeping 700-1600 Hz for 2 s, then the voice warning. Generated in memory, no sound files needed.
func makeSirenWAV(voice: [Int16] = [], seconds: Double = 2.0, rate: Int = 44_100) -> Data {
    let n = Int(seconds * Double(rate))
    var samples = [Int16](repeating: 0, count: n)
    var phase = 0.0
    for i in 0..<n {
        let t = Double(i) / Double(rate)
        let cycle = t.truncatingRemainder(dividingBy: 1.0)
        let tri = cycle < 0.5 ? cycle * 2 : (1 - cycle) * 2
        phase += 2 * Double.pi * (700 + 900 * tri) / Double(rate)
        samples[i] = Int16((sin(phase) >= 0 ? 0.9 : -0.9) * Double(Int16.max))
    }
    if !voice.isEmpty { samples += [Int16](repeating: 0, count: rate / 5) + voice + [Int16](repeating: 0, count: rate / 5) }
    let total = samples.count
    var d = Data()
    func ascii(_ s: String) { d.append(s.data(using: .ascii)!) }
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    ascii("RIFF"); u32(UInt32(36 + total * 2)); ascii("WAVE")
    ascii("fmt "); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
    ascii("data"); u32(UInt32(total * 2))
    samples.withUnsafeBytes { d.append(contentsOf: $0) }
    return d
}

final class Siren {
    private var player: AVAudioPlayer?
    private var wav: Data?
    var duration: TimeInterval { player?.duration ?? 0 }

    /// Builds the sound ahead of time so the alarm never waits on `say` when it fires.
    func prepare() -> Data {
        if let wav { return wav }
        let voice = makeVoiceSamples("This laptop is being stolen")
        if voice.isEmpty { note("WARNING: voice warning unavailable (say failed). Siren only.") }
        let data = makeSirenWAV(voice: voice)
        wav = data
        return data
    }

    @discardableResult
    func start(loops: Int = -1) -> Bool {
        do {
            let p = try AVAudioPlayer(data: prepare())
            p.numberOfLoops = loops
            p.volume = 1.0
            p.prepareToPlay()
            guard p.play() else { note("Siren failed to start playback."); return false }
            player = p
            return true
        } catch {
            note("Siren failed: \(error)")
            return false
        }
    }
    func stop() { player?.stop(); player = nil }
}

// MARK: - Password

func verifyPassword(user: String, password: String) -> Bool {
    do {
        let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication))
        let record = try node.record(withRecordType: kODRecordTypeUsers, name: user, attributes: nil)
        try record.verifyPassword(password)
        return true
    } catch {
        return false
    }
}

func startDisarmPrompt(user: String, onSuccess: @escaping () -> Void) {
    Thread {
        while true {
            guard let p = getpass("Password to disarm: ") else { sleep(1); continue }
            let pw = String(cString: p)
            if verifyPassword(user: user, password: pw) {
                DispatchQueue.main.async(execute: onSuccess)
                return
            }
            DispatchQueue.main.async { note("Wrong password.") }
        }
    }.start()
}

// MARK: - Push (ntfy)

/// Sends in the background so a bad connection never delays the siren. Retries 5 times.
func sendPushAsync(topic: String, title: String, message: String) {
    DispatchQueue.global().async {
        for _ in 1...5 {
            if sendPush(topic: topic, title: title, message: message) { note("Push sent."); return }
            sleep(3)
        }
        note("WARNING: push failed after 5 attempts.")
    }
}

// MARK: - Signals

var signalSources: [DispatchSourceSignal] = []
func handleSignals(_ handler: @escaping (Int32) -> Void) {
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { handler(sig) }
        src.resume()
        signalSources.append(src)
    }
}

// MARK: - Alarm

final class Alarm {
    enum State { case starting, countingDown, calibrating, armed, triggered, exiting }

    static let degradedMessage = "Motion sensor not working. Lid and charger triggers only."

    let config: Config
    let user: String
    let headless: Bool
    var state = State.starting

    // Published state for control clients. Never `.disarmed` until the engine is about to exit.
    private(set) var current = AlarmState.countdown(0)
    private(set) var warnings: [String] = []
    var degradedReason: String?
    var control: ControlServer?

    let waker = SPUWaker()
    let accel = Accelerometer()
    let siren = Siren()
    let pushTopic: String?
    var lidSensor: IOHIDDevice?

    var filtered: SIMD3<Double>?
    var calibration: [SIMD3<Double>] = []
    var baseline: SIMD3<Double>?
    var baseLid: Int?
    var baseAC = false

    var motionHits = 0
    var lidHits = 0
    var warnedStale = false

    var savedVolume: (volume: Float32, muted: UInt32)?
    var sleepWasDisabled = false
    var sleepChanged = false
    var cleanedUp = false
    var ticker: Timer?

    init(config: Config, user: String, headless: Bool) {
        self.config = config
        self.user = user
        self.headless = headless
        self.pushTopic = loadPushTopic(user: user)
    }

    func publish(_ s: AlarmState) {
        current = s
        control?.broadcast(encode(.state(s)))
    }

    func warn(_ text: String) {
        note("WARNING: \(text)")
        warnings.append(text)
        control?.broadcast(encode(.warning(text)))
    }

    /// Runs before any side effect.
    /// - A second engine must exit here without cleanup, which would undo the first engine's state.
    private func startControl() {
        let c = ControlServer(alarm: self, ownerUser: user)
        do {
            try c.start()
        } catch SocketError.alreadyRunning {
            fail("An alarm is already running.")
        } catch {
            fail("Cannot start the control socket: \(error)")
        }
        control = c
        publish(.countdown(config.countdown))
    }

    func start() {
        if headless { startControl() }
        if !headless { saveTerminal() }
        handleSignals { [weak self] sig in self?.onSignal(sig) }

        let woken = waker.wake(intervalMicros: config.reportIntervalMicros)
        note("Sensor drivers woken: \(woken)" + (waker.targeted ? " (accelerometer only)" : " (could not isolate accelerometer, woke all)"))

        accel.onSample = { [weak self] v in self?.onAccel(v) }
        if !accel.start(intervalMicros: config.reportIntervalMicros) { warn("Accelerometer not available. Motion trigger disabled.") }

        lidSensor = openLidSensor()
        if lidSensor == nil { warn("Lid angle sensor not available. Lid-angle trigger disabled.") }

        _ = siren.prepare()
        if pushTopic == nil { warn("Push not set up. Run: sudo ./laptop-alarm push-setup") }
        savedVolume = getVolume()
        sleepWasDisabled = isSleepDisabled()

        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }

        state = .countingDown
        var remaining = config.countdown
        publish(.countdown(remaining))
        note("Arming in \(remaining)s. Leave the laptop still, then lock the screen (Ctrl+Cmd+Q). Ctrl+C to cancel.")
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self, self.state == .countingDown else { t.invalidate(); return }
            remaining -= 1
            if remaining > 0 {
                self.publish(.countdown(remaining))
                if remaining <= 3 { note("\(remaining)...") }
            } else {
                t.invalidate()
                self.state = .calibrating
                self.publish(.calibrating)
                self.calibration.removeAll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.finishArming() }
            }
        }
    }

    func finishArming() {
        guard state == .calibrating else { return }
        if calibration.count >= 10 {
            baseline = calibration.reduce(SIMD3<Double>(repeating: 0), +) / Double(calibration.count)
        } else {
            note("WARNING: no accelerometer data during calibration. Motion trigger disabled.")
            degradedReason = Alarm.degradedMessage
        }
        baseLid = lidSensor.flatMap(readLidAngle)
        baseAC = onACPower()

        setSleepDisabled(true)
        sleepChanged = true

        var active: [String] = []
        if let b = baseline { active.append(String(format: "motion (tilt > %.1f°, shock > %.2fg, rest |a| = %.3fg)", config.tiltDegrees, config.shockG, length(b))) }
        if let l = baseLid { active.append("lid angle (rest \(l)°, ±\(Int(config.lidDegrees))°)") }
        active.append("lid closed")
        active.append(baseAC ? "charger unplugged" : "charger unplugged: OFF (armed on battery)")

        state = .armed
        publish(degradedReason.map { .degraded($0) } ?? .armed)
        note("ARMED. Triggers: " + active.joined(separator: "; "))
        if !headless { startDisarmPrompt(user: user) { [weak self] in self?.disarm() } }
    }

    func onAccel(_ v: SIMD3<Double>) {
        let f = filtered.map { $0 + 0.3 * (v - $0) } ?? v
        filtered = f
        switch state {
        case .calibrating:
            calibration.append(f)
        case .armed:
            guard let b = baseline else { return }
            let tilt = angleDegrees(f, b)
            let shock = abs(length(f) - length(b))
            if tilt > config.tiltDegrees || shock > config.shockG {
                motionHits += 1
                if motionHits >= config.sustainSamples {
                    trigger(String(format: "motion (tilt %.1f°, shock %.3fg)", tilt, shock))
                }
            } else {
                motionHits = 0
            }
        default:
            break
        }
    }

    func tick() {
        switch state {
        case .armed:
            if lidClosed() == true { trigger("lid closed"); return }
            if baseAC && !onACPower() { trigger("charger unplugged"); return }
            if let b = baseLid, let s = lidSensor, let a = readLidAngle(s) {
                if Double(abs(a - b)) > config.lidDegrees {
                    lidHits += 1
                    if lidHits >= 2 { trigger("lid angle \(b)° -> \(a)°"); return }
                } else {
                    lidHits = 0
                }
            }
            if baseline != nil && !warnedStale && Date().timeIntervalSince(accel.lastSample) > 2 {
                warnedStale = true
                note("WARNING: accelerometer stopped reporting. Motion trigger may be inactive.")
                degradedReason = Alarm.degradedMessage
                publish(.degraded(Alarm.degradedMessage))
            }
        case .triggered:
            setVolume(config.sirenVolume, muted: 0)
        default:
            break
        }
    }

    func trigger(_ reason: String) {
        guard state == .armed else { return }
        state = .triggered
        publish(.triggered(reason))
        note("ALARM TRIGGERED: \(reason)")
        setVolume(config.sirenVolume, muted: 0)
        siren.start()
        if let t = pushTopic { sendPushAsync(topic: t, title: "Laptop alarm triggered", message: reason) }
    }

    func disarm() {
        let wasTriggered = state == .triggered
        state = .exiting
        siren.stop()
        cleanup()
        note(wasTriggered ? "Disarmed after alarm." : "Disarmed. No alarm was triggered.")
        publish(.disarmed)
        exitSoon()
    }

    /// Only reachable from the control server, which checks the state first.
    func cancelFromClient() {
        state = .exiting
        cleanup()
        note("Cancelled before arming.")
        publish(.disarmed)
        exitSoon()
    }

    /// Gives the last lines a moment to reach the clients before the socket goes away.
    private func exitSoon() {
        guard let control else { exit(0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            control.stop()
            exit(0)
        }
    }

    func onSignal(_ sig: Int32) {
        if sig == SIGINT && (state == .armed || state == .triggered) {
            note("Ctrl+C is ignored while armed. Type your password to disarm.")
            return
        }
        siren.stop()
        cleanup()
        note(sig == SIGINT ? "Cancelled before arming." : "Stopped by signal \(sig). Settings restored.")
        control?.stop()
        exit(0)
    }

    func cleanup() {
        guard !cleanedUp else { return }
        cleanedUp = true
        ticker?.invalidate()
        if let v = savedVolume { setVolume(v.volume, muted: v.muted) }
        if sleepChanged && !sleepWasDisabled { setSleepDisabled(false) }
        accel.stop()
        waker.restore()
        restoreTerminal()
    }
}

// MARK: - Monitor

final class Monitor {
    let config: Config
    let waker = SPUWaker()
    let accel = Accelerometer()
    var lidSensor: IOHIDDevice?
    var filtered: SIMD3<Double>?
    var base: SIMD3<Double>?
    var count = 0
    var tilt = 0.0, shock = 0.0, peakTilt = 0.0, peakShock = 0.0

    init(config: Config) { self.config = config }

    func start() {
        handleSignals { [weak self] _ in self?.stop() }
        let woken = waker.wake(intervalMicros: config.reportIntervalMicros)
        print("Sensor drivers woken: \(woken)\(waker.targeted ? " (accelerometer only)" : " (all)")")
        accel.onSample = { [weak self] v in self?.onAccel(v) }
        if !accel.start(intervalMicros: config.reportIntervalMicros) { print("Accelerometer not available.") }
        lidSensor = openLidSensor()
        print("Keep still for 1 second to set the resting baseline. Ctrl+C to exit.\n")
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.render() }
    }

    func onAccel(_ v: SIMD3<Double>) {
        let f = filtered.map { $0 + 0.3 * (v - $0) } ?? v
        filtered = f
        count += 1
        if base == nil && count >= 50 { base = f }
        guard let b = base else { return }
        tilt = angleDegrees(f, b)
        shock = abs(length(f) - length(b))
        peakTilt = max(peakTilt, tilt)
        peakShock = max(peakShock, shock)
    }

    func render() {
        let f = filtered ?? SIMD3(repeating: .nan)
        let lid = lidSensor.flatMap(readLidAngle).map { "\($0)°" } ?? "n/a"
        let closed = lidClosed().map { $0 ? "yes" : "no" } ?? "n/a"
        let line = String(format: "X %+.3f  Y %+.3f  Z %+.3f  |a| %.3fg  tilt %4.1f° (peak %4.1f°)  shock %.3fg (peak %.3fg)  lid %@  closed %@  %@",
                          f.x, f.y, f.z, length(f), tilt, peakTilt, shock, peakShock, lid, closed, onACPower() ? "AC" : "battery")
        print("\u{1B}[2K\r" + line, terminator: "")
        fflush(stdout)
    }

    func stop() {
        print(String(format: "\n\nPeaks this session: tilt %.1f°, shock %.3fg", peakTilt, peakShock))
        print(String(format: "Current thresholds: tilt %.1f°, shock %.2fg", config.tiltDegrees, config.shockG))
        accel.stop()
        waker.restore()
        exit(0)
    }
}

// MARK: - Main

func usage() -> Never {
    print("""
    Usage:
      sudo ./laptop-alarm monitor      [--tilt N] [--shock G]
      sudo ./laptop-alarm test-siren
      sudo ./laptop-alarm push-setup
      (any command also accepts --user NAME to override SUDO_USER)
      sudo ./laptop-alarm arm         [--tilt N] [--shock G] [--lid N] [--countdown S] [--volume V] [--headless]
      ./laptop-alarm status           (no sudo) show the running alarm's state
      ./laptop-alarm disarm           (no sudo) disarm a running alarm with your password
    """)
    exit(0)
}

let args = Array(CommandLine.arguments.dropFirst())
invokingUser = resolveInvokingUser(arguments: args, environment: ProcessInfo.processInfo.environment)
guard let command = args.first else { usage() }

var config = Config()
var headless = false
var i = 1
while i < args.count {
    if args[i] == "--headless" {
        headless = true
        i += 1
        continue
    }
    let value = i + 1 < args.count ? args[i + 1] : ""
    switch args[i] {
    case "--tilt": config.tiltDegrees = Double(value) ?? config.tiltDegrees
    case "--shock": config.shockG = Double(value) ?? config.shockG
    case "--lid": config.lidDegrees = Double(value) ?? config.lidDegrees
    case "--countdown": config.countdown = max(3, Int(value) ?? config.countdown)
    case "--volume": config.sirenVolume = min(1, max(0, Float32(value) ?? config.sirenVolume))
    case "--user": break  // consumed by resolveInvokingUser
    default: fail("Unknown option: \(args[i])")
    }
    i += 2
}

let needsRoot = command != "status" && command != "disarm"
if needsRoot && geteuid() != 0 { fail("Run with sudo. Waking the accelerometer and blocking sleep need root.") }

var keepAlive: AnyObject?

switch command {
case "monitor":
    let m = Monitor(config: config)
    keepAlive = m
    m.start()
case "test-siren":
    if let v = getVolume() {
        print(String(format: "Current output volume: %.0f%%%@", v.volume * 100, v.muted == 1 ? " (muted)" : ""))
    } else {
        print("Could not read output volume. Volume forcing may not work.")
    }
    let s = Siren()
    keepAlive = s
    print(s.start(loops: 0) ? String(format: "Playing siren once (%.1f s) at current volume...", s.duration) : "Siren failed.")
    DispatchQueue.main.asyncAfter(deadline: .now() + s.duration + 0.5) { s.stop(); exit(0) }
case "push-setup":
    guard let user = invokingUser, let topicPath = pushTopicPath(user: user) else {
        fail("Run via sudo from your own account so the topic file goes in your home.")
    }
    let fresh = loadPushTopic(user: user) == nil
    guard let topic = loadPushTopic(user: user) ?? createPushTopic(user: user) else {
        fail("Could not write \(topicPath).")
    }
    print("\(fresh ? "Created" : "Using existing") topic: \(topic)")
    print("In the ntfy app: tap +, enter this topic name, and keep the default server (ntfy.sh).")
    print("Sending a test message...")
    let ok = sendPush(topic: topic, title: "Laptop alarm test", message: "Push is working.")
    print(ok ? "Sent. Check your phone." : "Send failed. Check the network.")
    exit(ok ? 0 : 1)
case "arm":
    guard let user = invokingUser else {
        fail("Run via sudo from your own account so the disarm password can be checked against your user.")
    }
    let a = Alarm(config: config, user: user, headless: headless)
    keepAlive = a
    a.start()
case "status":
    startStatusCommand()
case "disarm":
    startDisarmCommand()
default:
    usage()
}

RunLoop.main.run()
