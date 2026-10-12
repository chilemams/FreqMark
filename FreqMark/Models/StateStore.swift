import Foundation

// MARK: - Core model types

struct FrequencyMarker: Identifiable, Equatable, Codable, Hashable {
    var id: UUID = UUID()
    var frequencyHz: Double
    var label: String
    var colorHex: String
    var isVisible: Bool = true

    var color: RGBColor {
        get { RGBColor(hex: colorHex) ?? .markerBlue }
        set { colorHex = newValue.hex }
    }
}

struct CurveCapture: Identifiable, Equatable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var colorHex: String
    /// Log-frequency grid points (same grid as the live view: 512 points, 20 Hz ..< ~Nyquist)
    var values: [Float]
    var logFrequencies: [Double]
    var createdAt: Date
    var isVisible: Bool = true

    var color: RGBColor {
        get { RGBColor(hex: colorHex) ?? .captureGray }
        set { colorHex = newValue.hex }
    }
}

struct AudioDeviceDescriptor: Identifiable, Equatable {
    var id: String
    var name: String
}

/// B - A on a dB-like scale: 20*log10(b/a), i.e. how capture B differs from reference A.
/// Computed eagerly whenever either operand changes; rendered as its own colored layer.
struct DifferenceLayer: Identifiable, Equatable, Codable, Hashable {
    var id: UUID = UUID()
    /// capture id used as the A reference
    var baseID: UUID
    /// capture id used as B
    var compareID: UUID
    var colorHex: String
    var isVisible: Bool = true

    var color: RGBColor {
        get { RGBColor(hex: colorHex) ?? .diffRed }
        set { colorHex = newValue.hex }
    }
}

// MARK: - Simple RGB hex color helper (avoids importing SwiftUI in model layer)

struct RGBColor: Equatable, Codable, Hashable {
    var r, g, b: Double

    static let markerBlue = RGBColor(r: 0.20, g: 0.55, b: 0.95)
    static let captureGray = RGBColor(r: 0.55, g: 0.55, b: 0.55)
    static let diffRed = RGBColor(r: 0.95, g: 0.30, b: 0.25)
    static let diffPalette: [RGBColor] = [
        RGBColor(r: 0.95, g: 0.30, b: 0.25),
        RGBColor(r: 0.95, g: 0.55, b: 0.15),
        RGBColor(r: 0.45, g: 0.90, b: 0.30),
    ]
    static let capturePalette: [RGBColor] = [
        RGBColor(r: 0.95, g: 0.45, b: 0.35),
        RGBColor(r: 0.35, g: 0.80, b: 0.45),
        RGBColor(r: 0.90, g: 0.75, b: 0.30),
        RGBColor(r: 0.70, g: 0.45, b: 0.90),
        RGBColor(r: 0.35, g: 0.75, b: 0.85),
        RGBColor(r: 0.95, g: 0.60, b: 0.25),
    ]

    var hex: String {
        String(format: "#%02X%02X%02X", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }

    init(r: Double, g: Double, b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        r = Double((v >> 16) & 0xFF) / 255.0
        g = Double((v >> 8) & 0xFF) / 255.0
        b = Double(v & 0xFF) / 255.0
    }
}

// MARK: - Persistence

/// Persists markers + captures + diff layers to JSON in Application Support
/// (survives relaunch).
///
/// Thread model: Swift runs the app with concurrent UI (canvas drag, picker
/// menu tracking, watchDog timers); the store serializes ALL mutations on a
/// private queue so capture-add/remove/toggle from different UI paths can't
/// interleave (verified crash: an index-out-of-range when a marker-add raced
/// with a capture-toggle's array rebuild). Published-value notification is
/// marshalled to main within mutate().
final class StateStore: ObservableObject {
    @Published var markers: [FrequencyMarker] = []
    @Published var captures: [CurveCapture] = []
    @Published var diffLayers: [DifferenceLayer] = []

    private let queue = DispatchQueue(label: "FreqMark.persistence")
    private var directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = appSupport.appendingPathComponent("FreqMark", isDirectory: true)
        }
        // Ensure the directory exists even before first save (analyzers load
        // markers on startup from any prior session).
        if let dir = directory { self.directory = dir }
        load()
    }

    var persistenceDirectory: URL { directory }

    private var markersURL: URL { directory.appendingPathComponent("markers.json") }
    private var capturesURL: URL { directory.appendingPathComponent("captures.json") }
    private var diffURL: URL { directory.appendingPathComponent("diffs.json") }

    func load() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            NSLog("FreqMark: cannot create state dir: \(error)")
        }
        if let data = try? Data(contentsOf: markersURL),
           let loaded = try? JSONDecoder().decode([FrequencyMarker].self, from: data) {
            markers = loaded
        }
        if let data = try? Data(contentsOf: capturesURL),
           let loaded = try? JSONDecoder().decode([CurveCapture].self, from: data) {
            captures = loaded
        }
        if let data = try? Data(contentsOf: diffURL),
           let loaded = try? JSONDecoder().decode([DifferenceLayer].self, from: data) {
            diffLayers = loaded
        }
    }

    /// Test/debug hook: blocks until all queued saves have hit disk.
    /// Saves target the persistence queue serially, so a sync re-entry is a
    /// full flush. Test-only; production code should never call this.
    func flushForTesting() {
        queue.sync { }
    }

    /// Snapshot arrays ON MAIN (they belong to SwiftUI), then persist the
    /// snapshots off-main. Encoding array state owned by main from another
    /// thread is a data race (verified: index-out-of-range fatal in autorelease
    /// pool while tests mutated concurrent to saves).
    func save() {
        let snap: ([FrequencyMarker], [CurveCapture], [DifferenceLayer]) = Thread.isMainThread
            ? (markers, captures, diffLayers)
            : DispatchQueue.main.sync { (markers, captures, diffLayers) }
        queue.async { [self] in
            saveLocked(markers: snap.0, captures: snap.1, diffs: snap.2)
        }
    }

    /// Runs on `queue` with owned snapshots only — never touches live arrays.
    private func saveLocked(markers: [FrequencyMarker], captures: [CurveCapture], diffs: [DifferenceLayer]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(markers).write(to: markersURL, options: .atomic)
            try enc.encode(captures).write(to: capturesURL, options: .atomic)
            try enc.encode(diffs).write(to: diffURL, options: .atomic)
        } catch {
            NSLog("FreqMark save error: \(error)")
        }
    }

    /// Serializes a mutation ON MAIN (SwiftUI owns these arrays), then queues
    /// the disk save. All array mutations MUST go through here — direct
    /// property writes from background threads race the SwiftUI observer.
    private func mutate(_ body: () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.sync(execute: body) // background callers block briefly
        }
        save()
    }

    // MARK: - Marker operations

    func addMarker(frequencyHz: Double, label: String) -> FrequencyMarker {
        // Cycle through a small palette so consecutive pins differ in color.
        let snapshotPalette = RGBColor.capturePalette + [.markerBlue]
        let marker: FrequencyMarker = {
            let total = markers.count
            let color = snapshotPalette[total % snapshotPalette.count]
            return FrequencyMarker(frequencyHz: frequencyHz,
                                   label: label.isEmpty ? Self.markerAutoLabel(frequencyHz) : label,
                                   colorHex: color.hex)
        }()
        mutate {
            markers.append(marker)
        }
        return marker
    }

    static func markerAutoLabel(_ hz: Double) -> String {
        if hz >= 1000 {
            return String(format: "%.1fk", hz / 1000)
        }
        return String(format: "%.0fHz", hz)
    }

    func removeMarker(_ id: UUID) {
        mutate {
            markers.removeAll { $0.id == id }
        }
    }

    func updateMarkerFrequency(_ id: UUID, frequencyHz: Double) {
        mutate {
            if let idx = markers.firstIndex(where: { $0.id == id }) {
                markers[idx].frequencyHz = frequencyHz
            }
        }
    }

    // MARK: - Capture operations

    func addCapture(values: [Float], logFrequencies: [Double]) -> CurveCapture {
        let capture: CurveCapture = { [self] in
            let snapshotCount = captures.count
            let color = RGBColor.capturePalette[snapshotCount % RGBColor.capturePalette.count]
            return CurveCapture(
                name: "Capture \(snapshotCount + 1)",
                colorHex: color.hex,
                values: values,
                logFrequencies: logFrequencies,
                createdAt: Date()
            )
        }()
        mutate {
            captures.append(capture)
        }
        return capture
    }

    func removeCapture(_ id: UUID) {
        mutate {
            captures.removeAll { $0.id == id }
            diffLayers.removeAll { $0.baseID == id || $0.compareID == id }
        }
    }

    func toggleCaptureVisibility(_ id: UUID) {
        mutate {
            if let idx = captures.firstIndex(where: { $0.id == id }) {
                captures[idx].isVisible.toggle()
            }
        }
    }

    // MARK: - Difference layers

    func addDiff(baseID: UUID, compareID: UUID) {
        guard baseID != compareID else { return }
        let layer: DifferenceLayer = { [self] in
            let color = RGBColor.diffPalette[diffLayers.count % RGBColor.diffPalette.count]
            return DifferenceLayer(baseID: baseID, compareID: compareID, colorHex: color.hex)
        }()
        mutate {
            diffLayers.append(layer)
        }
    }

    func removeDiff(_ id: UUID) {
        mutate {
            diffLayers.removeAll { $0.id == id }
        }
    }

    func toggleDiffVisibility(_ id: UUID) {
        mutate {
            if let idx = diffLayers.firstIndex(where: { $0.id == id }) {
                diffLayers[idx].isVisible.toggle()
            }
        }
    }

    // MARK: - Reset

    /// Clear everything (markers, captures, diff layers) for a fresh round.
    func clearAll() {
        mutate {
            markers.removeAll()
            captures.removeAll()
            diffLayers.removeAll()
        }
    }
}
