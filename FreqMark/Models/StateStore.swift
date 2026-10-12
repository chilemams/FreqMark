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

enum StateStoreError: Error {
    case directoryCreationFailed
}

/// Persists markers + captures to JSON in Application Support (survives relaunch).
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
        load()
    }

    var persistenceDirectory: URL { directory }

    private var markersURL: URL { directory.appendingPathComponent("markers.json") }
    private var capturesURL: URL { directory.appendingPathComponent("captures.json") }
    private var diffURL: URL { directory.appendingPathComponent("diffs.json") }

    func load() {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
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

    func save() {
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                try enc.encode(markers).write(to: markersURL, options: .atomic)
                try enc.encode(captures).write(to: capturesURL, options: .atomic)
                try enc.encode(diffLayers).write(to: diffURL, options: .atomic)
            } catch {
                NSLog("FreqMark save error: \(error)")
            }
        }
    }

    // MARK: - Marker operations

    func addMarker(frequencyHz: Double, label: String) -> FrequencyMarker {
        // Cycle through a small palette so consecutive pins differ in color.
        let palette = RGBColor.capturePalette + [.markerBlue]
        let color = palette[markers.count % palette.count]
        let marker = FrequencyMarker(frequencyHz: frequencyHz, label: label.isEmpty ? markerAutoLabel(frequencyHz) : label, colorHex: color.hex)
        markers.append(marker)
        save()
        return marker
    }

    private func markerAutoLabel(_ hz: Double) -> String {
        if hz >= 1000 {
            return String(format: "%.1fk", hz / 1000)
        }
        return String(format: "%.0fHz", hz)
    }

    func removeMarker(_ id: UUID) {
        markers.removeAll { $0.id == id }
        save()
    }

    func updateMarkerFrequency(_ id: UUID, frequencyHz: Double) {
        if let idx = markers.firstIndex(where: { $0.id == id }) {
            markers[idx].frequencyHz = frequencyHz
            save()
        }
    }

    // MARK: - Capture operations

    func addCapture(values: [Float], logFrequencies: [Double]) -> CurveCapture {
        let palette = RGBColor.capturePalette
        let color = palette[captures.count % palette.count]
        let idx = captures.count + 1
        let capture = CurveCapture(
            name: "Capture \(idx)",
            colorHex: color.hex,
            values: values,
            logFrequencies: logFrequencies,
            createdAt: Date()
        )
        captures.append(capture)
        save()
        return capture
    }

    func removeCapture(_ id: UUID) {
        captures.removeAll { $0.id == id }
        save()
    }

    func toggleCaptureVisibility(_ id: UUID) {
        if let idx = captures.firstIndex(where: { $0.id == id }) {
            captures[idx].isVisible.toggle()
            save()
        }
    }

    // MARK: - Difference layers

    func addDiff(baseID: UUID, compareID: UUID) {
        guard baseID != compareID else { return }
        let color = RGBColor.diffPalette[diffLayers.count % RGBColor.diffPalette.count]
        let layer = DifferenceLayer(baseID: baseID, compareID: compareID, colorHex: color.hex)
        diffLayers.append(layer)
        save()
    }

    func removeDiff(_ id: UUID) {
        diffLayers.removeAll { $0.id == id }
        save()
    }

    func toggleDiffVisibility(_ id: UUID) {
        if let idx = diffLayers.firstIndex(where: { $0.id == id }) {
            diffLayers[idx].isVisible.toggle()
            save()
        }
    }
}
