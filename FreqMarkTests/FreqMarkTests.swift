import XCTest
@testable import FreqMark

final class StateStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: StateStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = StateStore(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// Saves are async (snapshot → persistence queue → disk); flush, then
    /// reload from what's on disk.
    private func reloadAfterSave() -> StateStore {
        store.flushForTesting()
        return StateStore(directory: tempDir)
    }

    func testMarkerRoundTripPersistsFrequencyAndLabel() {
        let m = store.addMarker(frequencyHz: 83.5, label: "low E fundamental")
        XCTAssertEqual(store.markers.count, 1)
        XCTAssertEqual(m.frequencyHz, 83.5, accuracy: 0.001)
        XCTAssertEqual(m.label, "low E fundamental")

        let store2 = reloadAfterSave()
        XCTAssertEqual(store2.markers.count, 1)
        XCTAssertEqual(store2.markers[0].id, m.id)
        XCTAssertEqual(store2.markers[0].frequencyHz, 83.5, accuracy: 0.001)
    }

    func testAutoLabelFormatting() {
        let low = store.addMarker(frequencyHz: 82.4, label: "")
        XCTAssertEqual(low.label, "82Hz")
        let high = store.addMarker(frequencyHz: 4400.0, label: "")
        XCTAssertEqual(high.label, "4.4k")
    }

    func testMarkerUpdateFrequencyPersists() {
        let m = store.addMarker(frequencyHz: 100, label: "test")
        store.updateMarkerFrequency(m.id, frequencyHz: 250)
        let store2 = reloadAfterSave()
        XCTAssertEqual(store2.markers[0].frequencyHz, 250, accuracy: 0.001)
    }

    func testRemoveMarker() {
        let m = store.addMarker(frequencyHz: 100, label: "x")
        store.removeMarker(m.id)
        XCTAssertTrue(store.markers.isEmpty)
        // removed marker must not reappear via reload
        let store2 = reloadAfterSave()
        XCTAssertTrue(store2.markers.isEmpty)
    }

    func testCaptureRoundTripWithValues() {
        let values: [Float] = (0..<FFTEngine.logPoints).map { Float($0) / Float(FFTEngine.logPoints) }
        let freqs = (0..<FFTEngine.logPoints).map { 20.0 * pow(1200.0, Double($0) / Double(FFTEngine.logPoints - 1)) }
        let c = store.addCapture(values: values, logFrequencies: freqs)
        XCTAssertEqual(c.values, values)

        let store2 = reloadAfterSave()
        XCTAssertEqual(store2.captures.count, 1)
        XCTAssertEqual(store2.captures[0].values.count, FFTEngine.logPoints)
        XCTAssertEqual(store2.captures[0].values[100], values[100])
    }

    func testDiffLayerRoundTrip() {
        let a = store.addCapture(values: Array(repeating: 0.5, count: FFTEngine.logPoints),
                                 logFrequencies: (0..<FFTEngine.logPoints).map { Double($0) })
        let b = store.addCapture(values: Array(repeating: 0.25, count: FFTEngine.logPoints),
                                 logFrequencies: (0..<FFTEngine.logPoints).map { Double($0) })
        store.addDiff(baseID: a.id, compareID: b.id)
        XCTAssertEqual(store.diffLayers.count, 1)

        let store2 = reloadAfterSave()
        XCTAssertEqual(store2.diffLayers.count, 1)
        XCTAssertEqual(store2.diffLayers[0].baseID, a.id)
        XCTAssertEqual(store2.diffLayers[0].compareID, b.id)
    }

    func testAddDiffIgnoresSameCapturePair() {
        let a = store.addCapture(values: Array(repeating: 0.5, count: FFTEngine.logPoints),
                                 logFrequencies: (0..<FFTEngine.logPoints).map { Double($0) })
        store.addDiff(baseID: a.id, compareID: a.id)
        XCTAssertTrue(store.diffLayers.isEmpty, "A−A diff is meaningless and must be rejected")
    }

    func testToggleCaptureVisibilityPersists() {
        let c = store.addCapture(values: Array(repeating: 0.5, count: FFTEngine.logPoints),
                                 logFrequencies: (0..<FFTEngine.logPoints).map { Double($0) })
        store.toggleCaptureVisibility(c.id)
        let store2 = reloadAfterSave()
        XCTAssertFalse(store2.captures[0].isVisible)
    }

    func testRemovingCaptureDropsItsDiffLayers() {
        let a = store.addCapture(values: Array(repeating: 0.5, count: FFTEngine.logPoints),
                                 logFrequencies: (0..<FFTEngine.logPoints).map { Double($0) })
        let b = store.addCapture(values: Array(repeating: 0.5, count: FFTEngine.logPoints),
                                 logFrequencies: (0..<FFTEngine.logPoints).map { Double($0) })
        store.addDiff(baseID: a.id, compareID: b.id)
        XCTAssertEqual(store.diffLayers.count, 1)
        store.removeCapture(a.id)
        XCTAssertTrue(store.diffLayers.isEmpty, "diff layers referencing a deleted capture are meaningless")
    }

    func testClearAllEmptiesStore() {
        let a = store.addCapture(values: Array(repeating: 0.5, count: FFTEngine.logPoints),
                                 logFrequencies: (0..<FFTEngine.logPoints).map { Double($0) })
        let b = store.addCapture(values: Array(repeating: 0.5, count: FFTEngine.logPoints),
                                 logFrequencies: (0..<FFTEngine.logPoints).map { Double($0) })
        _ = store.addMarker(frequencyHz: 80, label: "m")
        store.addDiff(baseID: a.id, compareID: b.id)

        store.clearAll()
        store.flushForTesting()
        XCTAssertTrue(store.markers.isEmpty && store.captures.isEmpty && store.diffLayers.isEmpty)

        let store2 = reloadAfterSave()
        XCTAssertTrue(store2.markers.isEmpty && store2.captures.isEmpty && store2.diffLayers.isEmpty)
    }
}

final class RGBColorTests: XCTestCase {
    func testHexRoundTrip() {
        let c = RGBColor(r: 0.95, g: 0.45, b: 0.35)
        let hex = c.hex
        let parsed = RGBColor(hex: hex)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.r, 0.95, accuracy: 1/255)
        XCTAssertEqual(parsed!.g, 0.45, accuracy: 1/255)
        XCTAssertEqual(parsed!.b, 0.35, accuracy: 1/255)
    }

    func testInvalidHexRejected() {
        XCTAssertNil(RGBColor(hex: "#12345"))
        XCTAssertNil(RGBColor(hex: "zzzzzz"))
        XCTAssertNil(RGBColor(hex: ""))
    }

    func testHashSignParsing() {
        let c = RGBColor(hex: "4A90D9") // no hash
        XCTAssertNotNil(c)
        XCTAssertEqual(c!.r, 0x4A / 255.0, accuracy: 0.001)
    }
}

final class LogGridMathTests: XCTestCase {
    func testLogFrequencyGridIsMonotonic() {
        let engine = FFTEngine()
        let grid = engine.logFrequencies
        XCTAssertEqual(grid.count, FFTEngine.logPoints)
        for i in 1..<grid.count {
            XCTAssertGreaterThan(grid[i], grid[i - 1], "grid must be strictly increasing")
        }
        XCTAssertEqual(grid[0], 20.0)
        XCTAssertLessThan(grid.last!, 24000)
    }

    func testSnapAlgorithmMatchesNearestLogPoint() {
        let engine = FFTEngine()
        let target = 100.0
        var best = engine.logFrequencies[0]
        var bestD = Double.infinity
        for cand in engine.logFrequencies {
            let d = abs(log10(cand) - log10(target))
            if d < bestD { bestD = d; best = cand }
        }
        // nearest log-grid point to 100 Hz should be within one bin spacing (~2%)
        XCTAssertEqual(best / target, 1.0, accuracy: 0.02)
    }
}
