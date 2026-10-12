import SwiftUI

/// Main window content: toolbar + spectrum plot with markers, captures, crosshair.
struct ContentView: View {
    @StateObject private var engine = FFTEngine()
    @StateObject private var store = StateStore()
    @State private var skipFrames = 0 // skip FFT frames periodically to lower render load
    @State private var hoverLocation: CGPoint? = nil
    @State private var dragMarkerId: UUID? = nil
    @State private var panX: CGFloat = 0 // 0..1 fraction of the range hidden at the start
    @State private var zoomSpan: CGFloat = 1.0 // 1.0 = full range, 0.1 = 10x zoomed
    @State private var pendingMarkerFrequency: Double? = nil
    @State private var showNamingSheet = false
    @State private var inputDevices: [AudioDeviceDescriptor] = []
    @AppStorage("freqmark.inputDeviceID") private var storedDeviceID = ""
    @State private var pendingDiffBase: UUID? = nil
    @State private var diffDisabledMessage: String? = nil
    @State private var showResetConfirm = false

    private static let minVisibleDecades: Double = 0.8

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack {
                SpectrumView(
                    engine: engine,
                    markers: store.markers,
                    captures: store.captures,
                    diffLayers: store.diffLayers,
                    panX: $panX,
                    zoomSpan: $zoomSpan,
                    dragMarkerId: $dragMarkerId,
                    hoverLocation: $hoverLocation,
                    onAddMarker: { freq in
                        pendingMarkerFrequency = freq
                        showNamingSheet = true
                    },
                    onRemoveMarker: { id in
                        store.removeMarker(id)
                    },
                    onMoveMarker: { id, freq in
                        store.updateMarkerFrequency(id, frequencyHz: freq)
                    }
                )
            }
            .overlay(alignment: .bottomTrailing) {
                zoomControls.padding(12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            Task { await engine.requestPermissionThenStart() }
        }
        .onDisappear {
            engine.stop()
        }
        .sheet(isPresented: $showNamingSheet) {
            MarkerNamingSheet(frequency: pendingMarkerFrequency ?? 0) { label in
                if let freq = pendingMarkerFrequency {
                    store.addMarker(frequencyHz: freq, label: label)
                }
                pendingMarkerFrequency = nil
            }
        }
        .confirmationDialog(
            "Clear everything?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear all markers, captures and diffs", role: .destructive) {
                store.clearAll()
                pendingDiffBase = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every marker pin, frozen capture and Δ diff layer. Live listening continues.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                if engine.isRunning {
                    engine.stop()
                } else {
                    Task { await engine.requestPermissionThenStart() }
                }
            } label: {
                Image(systemName: engine.isRunning ? "stop.fill" : "play.fill")
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)

            Button {
                let snapshot = engine.spectrum
                guard snapshot.contains(where: { $0 > 0 }) else { return }
                _ = store.addCapture(values: snapshot, logFrequencies: engine.logFrequencies)
            } label: {
                Label("Capture", systemImage: "camera.fill")
            }
            .buttonStyle(.bordered)
            .disabled(!engine.isRunning)

            Divider().frame(height: 20)

            // Captures list
            HStack(spacing: 6) {
                Text("Captures").font(.callout).foregroundStyle(.secondary)
                ForEach(store.captures) { c in
                    Button {
                        store.toggleCaptureVisibility(c.id)
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(color(c.colorHex)).frame(width: 8, height: 8)
                                .opacity(c.isVisible ? 1 : 0.3)
                            Text(c.name).font(.caption)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(c.isVisible ? Color.secondary.opacity(0.15) : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(diffSelectionState(c.id), lineWidth: 1.5)
                            .padding(-2)
                    )
                    .onTapGesture {
                        if let base = pendingDiffBase, base != c.id {
                            store.addDiff(baseID: base, compareID: c.id)
                            pendingDiffBase = nil
                        }
                        // otherwise: plain click = toggle visibility (handled by Button above)
                    }
                    .contextMenu {
                        Button("Rename") {}
                        Button("Set as diff reference (A)") { pendingDiffBase = c.id }
                        Button("Delete", role: .destructive) { store.removeCapture(c.id) }
                    }
                }
            }

            // Diff creation: click Diff to arm, then click any two capture chips
            Button {
                if store.captures.count < 2 {
                    diffDisabledMessage = "Capture at least two curves first (camera button), then use Diff."
                } else if pendingDiffBase == nil {
                    pendingDiffBase = store.captures.first?.id
                    diffDisabledMessage = nil
                } else {
                    pendingDiffBase = nil // disarm
                    diffDisabledMessage = nil
                }
            } label: {
                Label(pendingDiffBase == nil ? "Diff" : "Click second capture…",
                      systemImage: pendingDiffBase == nil ? "arrow.left.arrow.right" : "cursorarrow.click.2")
            }
            .buttonStyle(.bordered)
            .opacity(store.captures.count < 2 ? 0.75 : 1.0)
            .help("Creates a Δ layer showing how many dB capture B differs from capture A at every frequency. Click Diff, then click the reference capture chip, then the comparison chip.")

            // Diff layers list
            ForEach(store.diffLayers) { d in
                Button {
                    store.toggleDiffVisibility(d.id)
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(color(d.colorHex)).frame(width: 8, height: 8)
                            .opacity(d.isVisible ? 1 : 0.3)
                        Text(diffLabel(d)).font(.caption)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(d.isVisible ? Color.secondary.opacity(0.15) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Delete", role: .destructive) { store.removeDiff(d.id) }
                }
            }

            Spacer()

            Button {
                showResetConfirm = true
            } label: {
                Label("Reset", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .help("Clears all markers, captures and diff layers")

            // Input device picker
            Picker("Input", selection: $storedDeviceID) {
                ForEach(inputDevices) { d in
                    Text(d.name).tag(d.id)
                }
            }
            .frame(width: 190)
            .onChange(of: storedDeviceID) { _, newID in
                engine.useDevice(id: newID)
            }
            .onAppear {
                inputDevices = FFTEngine.listInputDevices()
                if storedDeviceID.isEmpty, let first = inputDevices.first {
                    storedDeviceID = first.id
                    engine.useDevice(id: first.id)
                } else if !storedDeviceID.isEmpty {
                    engine.useDevice(id: storedDeviceID)
                }
            }

            Text(engine.debugInfo.isEmpty ? "" : engine.debugInfo + " ")
                .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            Text(engine.isRunning ? "Listening…" : "Stopped")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            if let msg = diffDisabledMessage {
                Text(msg)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .transition(.opacity)
                    .task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        withAnimation { diffDisabledMessage = nil }
                    }
            }
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    zoomSpan = min(1.0, zoomSpan * 1.25)
                    clampPan()
                }
            } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.bordered)
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    zoomSpan = max(0.02, zoomSpan / 1.25)
                    clampPan()
                }
            } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.bordered)
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    zoomSpan = 1.0
                    panX = 0
                }
            } label: { Image(systemName: "arrow.uturn.backward.circle") }
                .buttonStyle(.bordered)
        }
        .font(.title3)
    }

    private func clampPan() {
        let maxPan = max(0, 1 - zoomSpan)
        panX = min(max(0, panX), maxPan)
    }

    private func color(_ hex: String) -> Color {
        if let rgb = RGBColor(hex: hex) {
            return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
        }
        return .secondary
    }

    /// Blue outline on the capture currently picked as diff reference A
    private func diffSelectionState(_ captureID: UUID) -> Color {
        pendingDiffBase == captureID ? Color.accentColor : Color.clear
    }

    private func diffLabel(_ d: DifferenceLayer) -> String {
        let a = store.captures.first(where: { $0.id == d.baseID })
        let b = store.captures.first(where: { $0.id == d.compareID })
        let aName = a?.name ?? "?"
        let bName = b?.name ?? "?"
        return "Δ \(bName) − \(aName)"
    }
}

// MARK: - Naming sheet after clicking to add a marker

struct MarkerNamingSheet: View {
    let frequency: Double
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label: String = ""

    var body: some View {
        VStack(spacing: 14) {
            Text("Add frequency marker").font(.headline)
            Text(String(format: "%.1f Hz", frequency)).foregroundStyle(.secondary)
            TextField("Label (optional)", text: $label)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit { submit() }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") { submit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 300)
    }

    private func submit() {
        onSubmit(label)
        dismiss()
    }
}

// MARK: - Spectrum renderer

struct SpectrumView: View {
    @ObservedObject var engine: FFTEngine
    let markers: [FrequencyMarker]
    let captures: [CurveCapture]
    var diffLayers: [DifferenceLayer]

    @Binding var panX: CGFloat
    @Binding var zoomSpan: CGFloat
    @Binding var dragMarkerId: UUID?
    @Binding var hoverLocation: CGPoint?

    var onAddMarker: (Double) -> Void
    var onRemoveMarker: (UUID) -> Void
    var onMoveMarker: (UUID, Double) -> Void // updates the marker with the given id

    // Drag intent state
    @State private var dragIntent: DragIntent = .none
    /// Marker under the cursor (for the delete chip)
    @State private var hoveredMarkerId: UUID? = nil

    enum DragIntent {
        case none
        case panning(startPan: CGFloat, startLocation: CGPoint)
        case draggingMarker(id: UUID)
    }

    var body: some View {
        GeometryReader { geo in
            let plot = CGRect(origin: .zero, size: geo.size)

            ZStack {
                Canvas { ctx, size in
                    drawGrid(ctx: ctx, size: size)
                    // captures under live trace
                    for c in captures where c.isVisible {
                        drawCurve(ctx: ctx, size: size, values: c.values, color: colorFor(c.colorHex), dimmed: true)
                    }
                    // differential layers (dB scale, centered band)
                    for d in diffLayers where d.isVisible {
                        if let curve = differenceCurve(d: d) {
                            drawDiffCurve(ctx: ctx, size: size, values: curve, color: colorFor(d.colorHex))
                        }
                    }
                    // live trace — hidden when stopped with captures visible
                    // (frozen curves read better without a dead blue line on top)
                    let hideLive = !engine.isRunning && !captures.isEmpty
                    if !hideLive {
                        drawCurve(ctx: ctx, size: size, values: engine.spectrum,
                                  color: Color(.controlAccentColor), lineWidth: 1.6, dimmed: false)
                    }
                    // markers
                    for m in markers where m.isVisible {
                        drawMarker(ctx: ctx, size: size, marker: m)
                    }
                    // crosshair
                    if let hover = hoverLocation {
                        drawCrosshair(ctx: ctx, size: size, at: hover)
                    }
                }

                // Hit-testing/drag surface only captures when it needs to act.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                handleDragChanged(v, size: geo.size)
                            }
                            .onEnded { v in
                                handleDragEnded(v, size: geo.size)
                            }
                    )
                    .onHover { hovering in
                        if !hovering {
                            hoverLocation = nil
                            hoveredMarkerId = nil
                        }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            hoverLocation = loc
                            hoveredMarkerId = markerAt(x: loc.x, size: geo.size)
                        case .ended:
                            hoverLocation = nil
                            hoveredMarkerId = nil
                        }
                    }

                // Marker delete chip: MUST be above the gesture surface or the
                // clear layer swallows its clicks (z-order bug, fixed here).
                if let hover = hoverLocation, let mid = hoveredMarkerId,
                   let marker = markers.first(where: { $0.id == mid }),
                   case .none = dragIntent {
                    let mx = freqToX(marker.frequencyHz, size: geo.size)
                    Button {
                        onRemoveMarker(marker.id)
                        hoveredMarkerId = nil
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "trash.fill")
                            Text("Delete \(marker.label)")
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .position(x: min(max(mx, 60), geo.size.width - 60), y: 36)
                }
            }
        }
    }

    // MARK: Frequency <-> geometry mapping (log axis, zoom + pan)

    private func freqToX(_ freq: Double, size: CGSize) -> CGFloat {
        let normLog = logNorm(freq)
        let x0 = CGFloat(normLog)
        let visibleStart = CGFloat(panX)
        let visibleSpan = CGFloat(zoomSpan)
        let frac = (x0 - visibleStart) / visibleSpan
        return frac * size.width
    }

    private func xToFreq(_ x: CGFloat, size: CGSize) -> Double {
        let frac = x / max(1, size.width)
        let visibleStart = panX
        let visibleSpan = zoomSpan
        let normLog = visibleStart + frac * visibleSpan
        return normLogToFreq(Double(normLog))
    }

    private func logNorm(_ freq: Double) -> Double {
        let minFreq = 20.0
        let maxFreq = FFTEngine.rootNyquist
        let v = (log10(freq) - log10(minFreq)) / (log10(maxFreq) - log10(minFreq))
        return min(max(v, 0), 1)
    }

    private func normLogToFreq(_ norm: Double) -> Double {
        let minFreq = 20.0
        let maxFreq = FFTEngine.rootNyquist
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)
        return pow(10, logMin + norm * (logMax - logMin))
    }

    // MARK: Drawing

    private func drawGrid(ctx: GraphicsContext, size: CGSize) {
        // Decade-anchored standard grid: 31.25, 62.5, 125, 250, 500, 1k, 2k, 4k, 8k, 16k
        let bins: [Double] = [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        for f in bins {
            let x = freqToX(f, size: size)
            if x < -2 || x > size.width + 2 { continue }
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(path, with: .color(Color.secondary.opacity(0.15)), lineWidth: 1)
            ctx.draw(Text(freqLabel(f)).font(.caption2).foregroundStyle(.secondary),
                     at: CGPoint(x: x + 4, y: size.height - 8), anchor: .leading)
        }
        // Horizontal dB guides: -80..0 in 10 dB steps (0 dB top, -80 bottom)
        let dBLabels: [Double] = [0, -10, -20, -30, -40, -50, -60, -70, -80]
        for db in dBLabels {
            let t = (-db / 80.0) * size.height // 0 dB → top, -80 → bottom
            let major = db == 0 || db == -40 || db == -80
            var path = Path()
            path.move(to: CGPoint(x: 0, y: t))
            path.addLine(to: CGPoint(x: size.width, y: t))
            ctx.stroke(path, with: .color(Color.secondary.opacity(major ? 0.22 : 0.10)), lineWidth: major ? 1 : 0.7)
            ctx.draw(Text(String(format: "%.0f", db)).font(.caption2).monospacedDigit().foregroundStyle(.secondary),
                     at: CGPoint(x: 5, y: t + 8), anchor: .leading)
        }
    }

    /// Unit label for the y axis
    private static let yUnit = "dB"

    private func freqLabel(_ f: Double) -> String {
        if f >= 1000 { return String(format: "%.4gkHz", f / 1000).replacingOccurrences(of: ".000", with: "") }
        return String(format: "%.4gHz", f)
    }

    private func drawCurve(ctx: GraphicsContext, size: CGSize, values: [Float], color: Color, lineWidth: CGFloat = 1.4, dimmed: Bool) {
        guard values.count == FFTEngine.logPoints, !values.isEmpty else { return }
        var path = Path()
        for (i, v) in values.enumerated() {
            let freq = engine.logFrequencies[i]
            let x = freqToX(freq, size: size)
            if x < -20 || x > size.width + 20 { continue }
            let y = (1 - CGFloat(min(max(v, 0), 1))) * size.height
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)

        if !dimmed {
            // Live trace gets the full treatment: soft glow underneath,
            // gradient area fill, then the crisp line on top.
            var glowPath = path
            ctx.stroke(glowPath, with: .color(color.opacity(0.18)),
                       style: StrokeStyle(lineWidth: lineWidth + 5, lineCap: .round, lineJoin: .round))
            ctx.stroke(glowPath, with: .color(color.opacity(0.10)),
                       style: StrokeStyle(lineWidth: lineWidth + 11, lineCap: .round, lineJoin: .round))

            // gradient area fill under the curve
            var fill = path
            fill.addLine(to: CGPoint(x: lastX(values, size: size), y: size.height))
            fill.addLine(to: CGPoint(x: firstX(values, size: size), y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [color.opacity(0.30), color.opacity(0.03), Color.clear]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)))
        }

        ctx.stroke(path, with: .color(color), style: style)
    }

    private func firstX(_ values: [Float], size: CGSize) -> CGFloat {
        freqToX(engine.logFrequencies.first ?? 20, size: size)
    }

    private func lastX(_ values: [Float], size: CGSize) -> CGFloat {
        freqToX(engine.logFrequencies.last ?? 1000, size: size)
    }

    private func drawMarker(ctx: GraphicsContext, size: CGSize, marker: FrequencyMarker) {
        let x = freqToX(marker.frequencyHz, size: size)
        guard x >= 0 && x <= size.width else { return }
        let c = colorFor(marker.colorHex)
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        ctx.stroke(line, with: .color(c.opacity(0.85)), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))

        let text = marker.label
        ctx.draw(Text(text).font(.caption).foregroundStyle(c),
                 at: CGPoint(x: x + 6, y: 10), anchor: .leading)
    }

    private func drawCrosshair(ctx: GraphicsContext, size: CGSize, at point: CGPoint) {
        var path = Path()
        path.move(to: CGPoint(x: point.x, y: 0))
        path.addLine(to: CGPoint(x: point.x, y: size.height))
        ctx.stroke(path, with: .color(Color.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        let f = xToFreq(point.x, size: size)

        // Readout: frequency + live dB + each visible capture / diff at this x
        var lines: [String] = [String(format: "%.1f Hz", f)]
        if engine.rawSpectrum.count == FFTEngine.logPoints {
            let idx = nearestLogIndex(freq: f)
            let v = Double(max(engine.rawSpectrum[idx], 1e-9))
            lines.append(String(format: "live %+.1f dB", 20 * log10(v)))
        }
        for c in captures where c.isVisible {
            if c.values.count == FFTEngine.logPoints {
                let idx = nearestLogIndex(freq: f)
                let peak = max(Double(c.values.max() ?? 1), 1e-9)
                let v = Double(max(c.values[idx], 1e-9))
                lines.append(String(format: "%@ %+.1f dB", c.name, 20 * log10(v / peak)))
            }
        }
        for d in diffLayers where d.isVisible {
            if let curve = differenceCurve(d: d), curve.count == FFTEngine.logPoints {
                let idx = nearestLogIndex(freq: f)
                lines.append(String(format: "Δ %+.1f dB", curve[idx]))
            }
        }

        let styled = Text(lines.joined(separator: "\n")).font(.caption).monospacedDigit().foregroundStyle(.primary)
        ctx.draw(styled, at: CGPoint(x: point.x, y: 30), anchor: .top)
    }

    /// Nearest log-grid index for a frequency (grid runs low→high Hz).
    private func nearestLogIndex(freq f: Double) -> Int {
        let grid = engine.logFrequencies
        guard !grid.isEmpty else { return 0 }
        let lf = log10(max(f, 1))
        let lo = log10(grid[0]), hi = log10(grid[grid.count - 1])
        let t = min(max((lf - lo) / (hi - lo), 0), 1)
        return min(Int((t * Double(grid.count - 1)).rounded()), grid.count - 1)
    }

    private func colorFor(_ hex: String) -> Color {
        if let rgb = RGBColor(hex: hex) {
            return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
        }
        return .secondary
    }

    // MARK: Difference layers (B − A in dB)

    /// 20·log10(B/A) per grid point, values clamped to ±diffRange.
    /// Both curves live on the same log grid, so this is pointwise.
    private func differenceCurve(d: DifferenceLayer) -> [Float]? {
        guard let a = captures.first(where: { $0.id == d.baseID }),
              let b = captures.first(where: { $0.id == d.compareID }),
              a.values.count == b.values.count else { return nil }
        let range: Float = 24
        return zip(b.values, a.values).map { bv, av in
            guard av > 1e-9, bv > 1e-9 else { return 0 }
            return min(max(20 * log10(bv / av), -range), range)
        }
    }

    /// Diff curves draw into a centered horizontal band (bottom 30% of the plot)
    /// with a zero line; scale: ±24 dB full band height, integer dB gridlines every 8 dB.
    private func drawDiffCurve(ctx: GraphicsContext, size: CGSize, values: [Float], color: Color) {
        guard values.count == FFTEngine.logPoints else { return }
        let bandHeight: CGFloat = size.height * 0.30
        let bandBottom = size.height
        let bandTop = bandBottom - bandHeight
        let mid = bandBottom - bandHeight / 2
        let halfSpan: CGFloat = 24 // dB at band edge

        // band bg + border + zero line
        var band = Path()
        band.addRect(CGRect(x: 0, y: bandTop, width: size.width, height: bandHeight))
        ctx.fill(band, with: .color(Color.black.opacity(0.35)))
        var zero = Path()
        zero.move(to: CGPoint(x: 0, y: mid))
        zero.addLine(to: CGPoint(x: size.width, y: mid))
        ctx.stroke(zero, with: .color(Color.secondary.opacity(0.35)), lineWidth: 0.7)

        // dB guides (+8, +16, −8, −16) with labels
        for db in [-16.0, -8.0, 8.0, 16.0] {
            let yOff = CGFloat(db / halfSpan) * (bandHeight / 2)
            let y = mid - yOff
            var g = Path()
            g.move(to: CGPoint(x: 0, y: y))
            g.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(g, with: .color(Color.secondary.opacity(0.15)), lineWidth: 0.7)
            ctx.draw(Text(String(format: "%+.0f", db)).font(.caption2).foregroundStyle(.secondary),
                     at: CGPoint(x: 24, y: y - 5), anchor: .leading)
        }
        ctx.draw(Text("Δ dB").font(.caption2).foregroundStyle(.secondary),
                 at: CGPoint(x: 24, y: bandTop + 4), anchor: .leading)

        // curve
        var path = Path()
        for (i, v) in values.enumerated() {
            let freq = engine.logFrequencies[i]
            let x = freqToX(freq, size: size)
            if x < -20 || x > size.width + 20 { continue }
            let frac = CGFloat(v) / (halfSpan * 1.0) // -1 .. 1
            let y = mid + frac * bandHeight / 2
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
    }

    // MARK: Drag handling: click=marker, drag marker, else pan/zoom

    private func markerAt(x: CGFloat, size: CGSize) -> UUID? {
        // is there a marker line near the click x?
        var best: (UUID, CGFloat)? = nil
        for m in markers where m.isVisible {
            let mx = freqToX(m.frequencyHz, size: size)
            let d = abs(mx - x)
            if d < 14 && (best == nil || d < best!.1) {
                best = (m.id, d)
            }
        }
        return best?.0
    }

    private func handleDragChanged(_ value: DragGesture.Value, size: CGSize) {
        switch dragIntent {
        case .none:
            // Debounce: decide intent on first movement
            let x = value.startLocation.x
            if let id = markerAt(x: x, size: size) {
                dragIntent = .draggingMarker(id: id)
                dragMarkerId = id
            } else {
                dragIntent = .panning(startPan: panX, startLocation: value.startLocation)
            }
        case .panning(let startPan, let startLoc):
            let dx = value.location.x - startLoc.x
            let maxPan = max(0, 1 - zoomSpan)
            let dNorm = -dx / max(1, size.width) * zoomSpan
            panX = min(max(startPan + dNorm, 0), maxPan)
        case .draggingMarker(let id):
            let f = xToFreq(value.location.x, size: size)
            if markers.contains(where: { $0.id == id }) {
                let snapped = snapToBin(freq: f, size: size)
                onMoveMarker(id, snapped)
            }
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value, size: CGSize) {
        let x = value.startLocation.x
        switch dragIntent {
        case .none, .panning:
            // exact click (no move): add a marker
            if abs(value.location.x - x) < 3 && abs(value.location.y - value.startLocation.y) < 3 {
                let f = snapToBin(freq: xToFreq(x, size: size), size: size)
                onAddMarker(f)
            }
        case .draggingMarker(let id):
            dragMarkerId = nil
            _ = id
        }
        dragIntent = .none
    }

    private func snapToBin(freq f: Double, size: CGSize) -> Double {
        // Snap to nearest displayed log-frequency point for consistent pin/curve alignment
        guard !engine.logFrequencies.isEmpty else { return f }
        var best = engine.logFrequencies[0]
        var bestD = Double.infinity
        for cand in engine.logFrequencies {
            let d = abs(log10(cand) - log10(f))
            if d < bestD { bestD = d; best = cand }
        }
        return best
    }
}

// MARK: - Marker drag delegate shim

// onMoveMarker closure takes only the frequency because SpectrumView already
// knows the id it is dragging (dragMarkerId binding).

extension FFTEngine {
    /// Nyquist of the fixed internal mapping (used for the log axis bounds)
    static var rootNyquist: Double { 24000.0 }
}
