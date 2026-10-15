import Foundation

let maxVoiceFileBytes = 10_000_000

/// Reads a regular file through one descriptor, so the checks and the read see the same file.
/// - Rejects symlinks, FIFOs, devices and anything over `maxBytes`. Never blocks on open.
func readRegularFile(_ path: String, maxBytes: Int) -> Data? {
    let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, Int(st.st_size) <= maxBytes else { return nil }
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 65_536)
    while true {
        let n = read(fd, &buf, buf.count)
        if n < 0 { return nil }
        if n == 0 { return data }
        data.append(contentsOf: buf[0..<n])
        if data.count > maxBytes { return nil }
    }
}

/// Mono 16-bit PCM WAV as peak-normalized samples. Empty if missing, malformed or silent.
func loadVoiceSamples(wavPath: String) -> [Int16] {
    guard let d = readRegularFile(wavPath, maxBytes: maxVoiceFileBytes), d.count > 12 else { return [] }
    var o = 12
    while o + 8 <= d.count {
        let id = String(decoding: d[o..<o + 4], as: UTF8.self)
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
            guard peak > 0 else { return [] }
            let gain = 0.9 * Double(Int16.max) / Double(peak)
            return s.map { Int16(Double($0) * gain) }
        }
        o += 8 + size + (size & 1)
    }
    return []
}

/// Arguments for `say` that write a mono 16-bit WAV file.
func sayArguments(text: String, to path: String, rate: Int) -> [String] {
    ["-o", path, "--file-format=WAVE", "--data-format=LEI16@\(rate)", text]
}

/// Runs `say` as the calling user. True when the file exists and is non-empty.
func renderVoiceFile(text: String, to path: String, rate: Int = 44_100) -> Bool {
    run("/usr/bin/say", sayArguments(text: text, to: path, rate: rate))
    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
    return size > 0
}
