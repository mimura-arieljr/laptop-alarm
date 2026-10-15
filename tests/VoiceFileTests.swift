import Foundation

func runVoiceFileTests() {
    testLoadParsesFillerChunk()
    testLoadRejectsBadInput()
    testRenderThenLoad()
}

private func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }

private func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
    Array(id.utf8) + le32(body.count) + body + (body.count & 1 == 1 ? [0] : [])
}

private func makeWav(samples: [Int16], filler: Int) -> Data {
    let fmt: [UInt8] = [1, 0, 1, 0] + le32(44_100) + le32(88_200) + [2, 0, 16, 0]
    var body = Array("WAVE".utf8) + chunk("fmt ", fmt)
    if filler > 0 { body += chunk("FLLR", [UInt8](repeating: 0, count: filler)) }
    body += chunk("data", samples.flatMap { s -> [UInt8] in
        let u = UInt16(bitPattern: s)
        return [UInt8(u & 0xFF), UInt8(u >> 8)]
    })
    return Data(Array("RIFF".utf8) + le32(body.count) + body)
}

private func writeTemp(_ data: Data) -> String {
    let path = NSTemporaryDirectory() + "laptop-alarm-test-\(UUID().uuidString).wav"
    FileManager.default.createFile(atPath: path, contents: data)
    return path
}

func testLoadParsesFillerChunk() {
    let path = writeTemp(makeWav(samples: [0, 1000, -2000, 500], filler: 4030))
    defer { try? FileManager.default.removeItem(atPath: path) }
    let s = loadVoiceSamples(wavPath: path)
    expect(s.count == 4, "filler wav loads 4 samples, got \(s.count)")
    let peak = s.map { abs(Int($0)) }.max() ?? 0
    let want = Int(0.9 * Double(Int16.max))
    expect(abs(peak - want) <= 1, "peak normalized to 0.9 full scale, got \(peak)")
}

func testLoadRejectsBadInput() {
    let zero = writeTemp(makeWav(samples: [0, 0, 0, 0], filler: 0))
    let short = writeTemp(Data("RIFF".utf8))
    defer { for p in [zero, short] { try? FileManager.default.removeItem(atPath: p) } }
    expect(loadVoiceSamples(wavPath: zero).isEmpty, "all-zero audio is rejected")
    expect(loadVoiceSamples(wavPath: short).isEmpty, "truncated header is rejected")
    expect(loadVoiceSamples(wavPath: "/nonexistent/laptop-alarm-test.wav").isEmpty, "missing file is rejected")
}

func testRenderThenLoad() {
    let path = NSTemporaryDirectory() + "laptop-alarm-test-\(UUID().uuidString).wav"
    defer { try? FileManager.default.removeItem(atPath: path) }
    expect(renderVoiceFile(text: "This laptop is being stolen", to: path), "say renders a file")
    let n = loadVoiceSamples(wavPath: path).count
    expect(n >= 40_000 && n <= 120_000, "rendered voice length is plausible, got \(n) samples")
}
