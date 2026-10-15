// sensor_probe_v2.swift
// Finds which SPU sensors actually change their VALUES when the laptop moves.
// Use it on a Mac where Laptop Alarm shows the orange "degraded" state.
//
// Build (from the repo root):  mkdir -p build && swiftc -O tools/sensor_probe_v2.swift -o build/probe
// Run:    ./build/probe                 (listen only)
//         sudo WAKE=1 ./build/probe     (also tries to wake sleeping SPU sensors, e.g. an IMU)
//
// The WAKE step writes undocumented properties to Apple's sensor driver.
// Expected to reset on reboot. Skip it if you'd rather not.

import Foundation
import IOKit
import IOKit.hid

// MARK: - Helpers

func intProp(_ d: IOHIDDevice, _ key: String) -> Int {
    (IOHIDDeviceGetProperty(d, key as CFString) as? NSNumber)?.intValue ?? -1
}
func strProp(_ d: IOHIDDevice, _ key: String) -> String {
    (IOHIDDeviceGetProperty(d, key as CFString) as? String) ?? "?"
}
func hex(_ v: Int) -> String { v < 0 ? "n/a" : String(format: "0x%04X", v) }
func hexBytes(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }

final class Tracker {
    let label: String
    let buffer: UnsafeMutablePointer<UInt8>
    let size: Int
    var phase = 0
    var samples: [[[UInt8]]] = [[], []]   // [still, moving]

    init(label: String, size: Int) {
        self.label = label
        self.size = size
        self.buffer = .allocate(capacity: size)
    }
    func add(_ bytes: [UInt8]) {
        if samples[phase].count < 5000 { samples[phase].append(bytes) }
    }
}

let reportCallback: IOHIDReportCallback = { context, _, _, _, _, report, length in
    guard let context else { return }
    let t = Unmanaged<Tracker>.fromOpaque(context).takeUnretainedValue()
    t.add(Array(UnsafeBufferPointer(start: report, count: Int(length))))
}

/// Max minus min of each byte position across samples.
func byteRanges(_ s: [[UInt8]]) -> [Int] {
    guard let n = s.map(\.count).max(), n > 0 else { return [] }
    return (0..<n).map { i in
        let vals = s.compactMap { i < $0.count ? Int($0[i]) : nil }
        guard let mn = vals.min(), let mx = vals.max() else { return 0 }
        return mx - mn
    }
}

// MARK: - 1. Optional wake of SPU sensor drivers

if ProcessInfo.processInfo.environment["WAKE"] == "1" {
    print("=== Waking SPU sensor drivers ===")
    let props: [(String, Int)] = [
        ("SensorPropertyReportingState", 1),
        ("SensorPropertyPowerState", 1),
        ("ReportInterval", 10_000),
    ]
    var ok = [String: Int](), fail = [String: Int]()
    var it: io_iterator_t = 0
    if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &it) == KERN_SUCCESS {
        var s = IOIteratorNext(it)
        while s != 0 {
            for (k, v) in props {
                let r = IORegistryEntrySetCFProperty(s, k as CFString, NSNumber(value: v))
                if r == KERN_SUCCESS { ok[k, default: 0] += 1 } else { fail[k, default: 0] += 1 }
            }
            IOObjectRelease(s)
            s = IOIteratorNext(it)
        }
        IOObjectRelease(it)
    }
    for (k, _) in props { print("\(k): \(ok[k] ?? 0) ok, \(fail[k] ?? 0) failed") }
    print()
}

// MARK: - 2. Open SPU sensor devices

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, nil)
let devices = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? []

var trackers: [Tracker] = []
var lidDevices: [(IOHIDDevice, Tracker)] = []

print("=== SPU sensor devices ===")
for d in devices where strProp(d, "Transport").uppercased().contains("SPU") {
    let page = intProp(d, "PrimaryUsagePage")
    let usage = intProp(d, "PrimaryUsage")
    let label = "page \(hex(page)) usage \(hex(usage)) pid \(hex(intProp(d, "ProductID")))"

    let r = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
    guard r == kIOReturnSuccess else {
        print("- \(label): open failed \(String(format: "0x%08X", r))")
        continue
    }
    print("- \(label): opened")

    _ = IOHIDDeviceSetProperty(d, "ReportInterval" as CFString, NSNumber(value: 10_000))

    var size = intProp(d, "MaxInputReportSize")
    if size <= 0 { size = 64 }
    let t = Tracker(label: label + " [input reports]", size: size)
    trackers.append(t)
    IOHIDDeviceRegisterInputReportCallback(d, t.buffer, size, reportCallback,
                                           Unmanaged.passUnretained(t).toOpaque())
    IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

    // Likely lid angle sensor: also poll it on demand via feature report.
    if page == 0x20 && usage == 0x8A {
        let ft = Tracker(label: label + " [feature report poll]", size: 64)
        trackers.append(ft)
        lidDevices.append((d, ft))
    }
}

// Poll feature reports 10x per second.
var firstPollResult: [String: IOReturn] = [:]
let pollTimer = Timer(timeInterval: 0.1, repeats: true) { _ in
    for (d, t) in lidDevices {
        var buf = [UInt8](repeating: 0, count: 64)
        var len = CFIndex(64)
        let r = buf.withUnsafeMutableBufferPointer {
            IOHIDDeviceGetReport(d, kIOHIDReportTypeFeature, 1, $0.baseAddress!, &len)
        }
        if firstPollResult[t.label] == nil { firstPollResult[t.label] = r }
        if r == kIOReturnSuccess { t.add(Array(buf.prefix(Int(len)))) }
    }
}
RunLoop.current.add(pollTimer, forMode: .default)

guard !trackers.isEmpty else {
    print("No SPU devices could be opened. Grant Terminal Input Monitoring, or try with sudo.")
    exit(0)
}

// MARK: - 3. Still vs moving

print("\nPhase 1: hands off, keep the laptop COMPLETELY STILL for 5 seconds...")
CFRunLoopRunInMode(.defaultMode, 5, false)
trackers.forEach { $0.phase = 1 }
print("Phase 2: tilt the lid slowly through a wide angle, then lift the whole laptop. 10 seconds...")
CFRunLoopRunInMode(.defaultMode, 10, false)
pollTimer.invalidate()

// MARK: - 4. Results

for (label, r) in firstPollResult where r != kIOReturnSuccess {
    print("\nFeature poll failed for \(label): \(String(format: "0x%08X", r))")
}

print("\n=== Results ===")
for t in trackers {
    let still = t.samples[0], moving = t.samples[1]
    let rs = byteRanges(still), rm = byteRanges(moving)

    // A byte "responds to motion" if it varies much more while moving than while still.
    // Counters/timestamps vary in both phases and are excluded.
    let motionBytes = rm.indices.filter { i in
        let s = i < rs.count ? rs[i] : 0
        return rm[i] >= max(s * 3, s + 8)
    }

    let verdict: String
    if still.isEmpty && moving.isEmpty { verdict = "silent" }
    else if !motionBytes.isEmpty { verdict = "RESPONDS TO MOTION (bytes \(motionBytes.map(String.init).joined(separator: ",")))" }
    else { verdict = "active, values not motion-correlated" }

    print("\n\(t.label)")
    print("  reports: still \(still.count), moving \(moving.count)  ->  \(verdict)")
    if let a = still.first { print("  first still:  \(hexBytes(a))") }
    if let b = moving.last { print("  last moving:  \(hexBytes(b))") }
    if !rm.isEmpty {
        print("  byte range still:  \(rs.map(String.init).joined(separator: " "))")
        print("  byte range moving: \(rm.map(String.init).joined(separator: " "))")
    }
}
