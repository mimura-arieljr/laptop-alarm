#!/usr/bin/env swift
// sensor_probe.swift
// Discovers which sensors this MacBook exposes that could detect lifting/tilting.
// Run: swift sensor_probe.swift
// Read-only except for requesting a faster ReportInterval on sensor devices.

import Foundation
import IOKit
import IOKit.hid
import IOKit.ps

// MARK: - Helpers

func intProp(_ d: IOHIDDevice, _ key: String) -> Int {
    (IOHIDDeviceGetProperty(d, key as CFString) as? NSNumber)?.intValue ?? -1
}

func strProp(_ d: IOHIDDevice, _ key: String) -> String {
    (IOHIDDeviceGetProperty(d, key as CFString) as? String) ?? "?"
}

func hex(_ v: Int) -> String { v < 0 ? "n/a" : String(format: "0x%04X", v) }

final class Tracker {
    let label: String
    let buffer: UnsafeMutablePointer<UInt8>
    let size: Int
    var phase = 0                 // 0 = still, 1 = moving
    var reports = [0, 0]          // reports received per phase
    var changed = [0, 0]          // reports whose bytes differed from the previous one
    var last: [UInt8] = []

    init(label: String, size: Int) {
        self.label = label
        self.size = size
        self.buffer = .allocate(capacity: size)
    }
}

let reportCallback: IOHIDReportCallback = { context, _, _, _, _, report, length in
    guard let context else { return }
    let t = Unmanaged<Tracker>.fromOpaque(context).takeUnretainedValue()
    let bytes = Array(UnsafeBufferPointer(start: report, count: Int(length)))
    t.reports[t.phase] += 1
    if !t.last.isEmpty && bytes != t.last { t.changed[t.phase] += 1 }
    t.last = bytes
}

// MARK: - 1. Power source and lid state (public, reliable)

print("=== Power & lid ===")
let psInfo = IOPSCopyPowerSourcesInfo().takeRetainedValue()
let source = IOPSGetProvidingPowerSourceType(psInfo).takeUnretainedValue() as String
print("Power source: \(source)  (charger-unplug trigger: available)")

let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
if rootDomain != 0,
   let clam = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString,
                                              kCFAllocatorDefault, 0)?.takeRetainedValue() {
    print("Lid closed state readable: \(clam)  (lid-close trigger: available)")
} else {
    print("Lid closed state: not readable")
}
IOObjectRelease(rootDomain)

// MARK: - 2. SPU (sensor processor) services in the IORegistry

var iter: io_iterator_t = 0
var spuCount = 0
if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDevice"), &iter) == KERN_SUCCESS {
    var s = IOIteratorNext(iter)
    while s != 0 { spuCount += 1; IOObjectRelease(s); s = IOIteratorNext(iter) }
    IOObjectRelease(iter)
}
print("\nAppleSPUHIDDevice services found: \(spuCount)")

// MARK: - 3. HID sensor inventory

print("\n=== Candidate HID sensor devices ===")
let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, nil)
let devices = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? []

var trackers: [Tracker] = []

for d in devices {
    let page = intProp(d, "PrimaryUsagePage")
    let usage = intProp(d, "PrimaryUsage")
    let transport = strProp(d, "Transport")
    let product = strProp(d, "Product")

    // Sensor page (0x20), vendor-defined pages, or anything on the SPU transport.
    let isCandidate = page == 0x20 || page >= 0xFF00 || transport.uppercased().contains("SPU")
    guard isCandidate else { continue }

    let label = "\(product) | page \(hex(page)) usage \(hex(usage)) | vid \(hex(intProp(d, "VendorID"))) pid \(hex(intProp(d, "ProductID"))) | \(transport)"
    print("- \(label)")

    let openResult = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
    if openResult != kIOReturnSuccess {
        print("    open failed: \(String(format: "0x%08X", openResult))")
        continue
    }

    // Some sensors only stream after a report interval is requested (microseconds).
    _ = IOHIDDeviceSetProperty(d, "ReportInterval" as CFString, NSNumber(value: 10_000))

    var size = intProp(d, "MaxInputReportSize")
    if size <= 0 { size = 64 }
    let t = Tracker(label: label, size: size)
    trackers.append(t)

    IOHIDDeviceRegisterInputReportCallback(d, t.buffer, size, reportCallback,
                                           Unmanaged.passUnretained(t).toOpaque())
    IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
}

if trackers.isEmpty {
    print("\nNo sensor devices could be opened. If opens failed with a permission error,")
    print("grant your terminal app Input Monitoring in System Settings > Privacy & Security, then rerun.")
    exit(0)
}

// MARK: - 4. Still vs moving test

print("\nPhase 1: keep the laptop COMPLETELY STILL (hands off) for 5 seconds...")
CFRunLoopRunInMode(.defaultMode, 5, false)

trackers.forEach { $0.phase = 1 }
print("Phase 2: tilt the lid back and forth, then lift the laptop a few cm. 10 seconds...")
CFRunLoopRunInMode(.defaultMode, 10, false)

// MARK: - 5. Results

print("\n=== Results (sorted by changes while moving) ===")
for t in trackers.sorted(by: { $0.changed[1] > $1.changed[1] }) {
    let stillRate = Double(t.changed[0]) / 5.0
    let moveRate = Double(t.changed[1]) / 10.0
    var verdict = "silent"
    if t.reports[0] + t.reports[1] > 0 {
        verdict = moveRate > max(stillRate * 3, 1) ? "RESPONDS TO MOTION" : "reports, but not motion-correlated"
    }
    print("""
    \(t.label)
        still:  \(t.reports[0]) reports, \(t.changed[0]) changed
        moving: \(t.reports[1]) reports, \(t.changed[1]) changed
        -> \(verdict)
    """)
}

print("""

How to read this:
- A device marked RESPONDS TO MOTION that also reported while still (at a steady rate) is likely an accelerometer/IMU.
- A device that only reports when the lid hinge moves is likely the lid angle sensor.
- The ambient light sensor can false-positive because your hands change the light. Ignore anything named like ALS.
""")
