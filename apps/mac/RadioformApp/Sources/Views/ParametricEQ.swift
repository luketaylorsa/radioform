import SwiftUI
import AppKit

// MARK: - Scale & Formatting

/// Maps between graph coordinates and frequency (log scale) / gain (linear dB)
struct EQGraphScale {
    static let minHz: Float = 20
    static let maxHz: Float = 20000
    /// Visible range is ±displayDb; band gain itself is limited to ±12 dB
    static let displayDb: Float = 15

    let size: CGSize

    func x(forHz hz: Float) -> CGFloat {
        let t = log10(hz / Self.minHz) / log10(Self.maxHz / Self.minHz)
        return CGFloat(t) * size.width
    }

    func hz(forX x: CGFloat) -> Float {
        let t = Float(min(max(x / size.width, 0), 1))
        return Self.minHz * pow(Self.maxHz / Self.minHz, t)
    }

    func y(forDb db: Float) -> CGFloat {
        CGFloat((Self.displayDb - db) / (2 * Self.displayDb)) * size.height
    }

    /// dB change for a vertical movement of `dy` points
    func dbDelta(forDy dy: CGFloat) -> Float {
        -Float(dy / size.height) * 2 * Self.displayDb
    }

    func db(forY y: CGFloat) -> Float {
        Self.displayDb + dbDelta(forDy: y)
    }
}

enum EQFormat {
    static func frequency(_ hz: Float) -> String {
        if hz < 1000 { return String(format: "%.0f Hz", hz) }
        if hz < 10000 { return String(format: "%.2f kHz", hz / 1000) }
        return String(format: "%.1f kHz", hz / 1000)
    }

    static func gain(_ db: Float) -> String {
        String(format: "%+.1f dB", db)
    }

    static func q(_ q: Float) -> String {
        String(format: "%.2f", q)
    }

    /// Parse user-entered frequency text ("1k", "1.5 kHz", "250", "250hz")
    static func parseFrequency(_ text: String) -> Float? {
        var t = text.lowercased().replacingOccurrences(of: " ", with: "")
        if t.hasSuffix("hz") { t = String(t.dropLast(2)) }
        if t.hasSuffix("k") { return Float(t.dropLast()).map { $0 * 1000 } }
        return Float(t)
    }

    /// Parse a plain number, tolerating a leading "+" and a trailing "dB"
    static func parseNumber(_ text: String) -> Float? {
        var t = text.lowercased().replacingOccurrences(of: " ", with: "")
        if t.hasSuffix("db") { t = String(t.dropLast(2)) }
        if t.hasPrefix("+") { t = String(t.dropFirst()) }
        return Float(t)
    }
}

/// Stable per-slot colors so a band keeps its color while you work on it
enum EQBandColor {
    static func color(_ index: Int) -> Color {
        Color(hue: Double(index) / Double(PresetManager.bandCount) * 0.9, saturation: 0.55, brightness: 0.95)
    }
}

/// Hold Shift while dragging or scrolling for fine adjustment
private func fineFactor() -> Float {
    NSEvent.modifierFlags.contains(.shift) ? 0.2 : 1
}

// MARK: - Parametric EQ

struct ParametricEQ: View {
    @ObservedObject private var presetManager = PresetManager.shared

    private let graphHeight: CGFloat = 150

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Preamp
            VStack(spacing: 4) {
                VerticalSlider(
                    value: Binding(
                        get: { presetManager.currentPreampDb },
                        set: { presetManager.updatePreamp(gainDb: $0) }
                    ),
                    range: -12...12,
                    isFocused: presetManager.focusedBandIndex == 10,
                    onDoubleTap: {
                        presetManager.toggleFocusedBand(10)
                    }
                )
                .frame(width: 20, height: graphHeight)

                Text("Pre")
                    .font(.system(size: 9))
                    .foregroundColor(.accentColor.opacity(0.7))
                    .frame(height: 12)
            }

            VStack(spacing: 4) {
                EQGraph()
                    .frame(height: graphHeight)

                FrequencyAxisLabels()
                    .frame(height: 12)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

// MARK: - Graph

/// Snapshot of one active band, taken in `body` so the Canvas redraws when it changes
private struct BandSnapshot {
    let index: Int
    let frequencyHz: Float
    let gainDb: Float
    let qFactor: Float
    let filterType: FilterType

    var coeffs: EQResponse.Coeffs {
        EQResponse.coefficients(frequencyHz: frequencyHz, gainDb: gainDb, q: qFactor, type: filterType)
    }

    /// Pass/notch filters have no gain, so their node sits on the 0 dB line
    var nodeDb: Float {
        filterType.usesGain ? gainDb : 0
    }
}

struct EQGraph: View {
    @ObservedObject private var presetManager = PresetManager.shared

    @State private var hoveredBand: Int?
    @State private var draggingBand: Int?
    @State private var lastDragTranslation: CGSize = .zero

    private static let gridFrequencies: [Float] = [50, 100, 200, 500, 1000, 2000, 5000, 10000]
    private static let gridDb: [Float] = [-12, -6, 0, 6, 12]

    private var bands: [BandSnapshot] {
        (0..<PresetManager.bandCount)
            .filter { presetManager.currentEnabled[$0] }
            .map {
                BandSnapshot(
                    index: $0,
                    frequencyHz: presetManager.currentFrequencies[$0],
                    gainDb: presetManager.currentBands[$0],
                    qFactor: presetManager.currentQFactors[$0],
                    filterType: presetManager.currentFilterTypes[$0]
                )
            }
    }

    private var selectedBand: Int? {
        guard let index = presetManager.focusedBandIndex,
              index < PresetManager.bandCount,
              presetManager.currentEnabled[index] else { return nil }
        return index
    }

    var body: some View {
        let bands = self.bands
        let selected = selectedBand

        GeometryReader { geometry in
            let scale = EQGraphScale(size: geometry.size)

            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawGrid(in: &context, scale: EQGraphScale(size: size))
                    drawCurves(in: &context, scale: EQGraphScale(size: size), bands: bands, selected: selected)
                }

                // Empty-area interactions: double-click adds a band, click deselects
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, coordinateSpace: .local) { location in
                        addBand(at: location, scale: scale)
                    }
                    .onTapGesture {
                        presetManager.setFocusedBand(nil)
                    }

                if bands.isEmpty {
                    Text("Double-click to add a band")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }

                ForEach(bands, id: \.index) { band in
                    node(band, isSelected: band.index == selected, scale: scale)
                }

                if let index = draggingBand ?? hoveredBand,
                   let band = bands.first(where: { $0.index == index }) {
                    readout(band, scale: scale)
                }
            }
            .background(
                // Scroll adjusts Q of the hovered band, or the selected one
                ScrollWheelReceiver { delta in
                    guard let index = hoveredBand ?? selectedBand else { return }
                    let q = presetManager.currentQFactors[index] * pow(2, Float(delta) * 0.05 * fineFactor())
                    presetManager.updateBandQ(index: index, qFactor: q)
                }
            )
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(NSColor.separatorColor).opacity(0.12))
        )
    }

    // MARK: Nodes

    private func node(_ band: BandSnapshot, isSelected: Bool, scale: EQGraphScale) -> some View {
        let isHot = isSelected || hoveredBand == band.index || draggingBand == band.index
        let diameter: CGFloat = isHot ? 16 : 13

        return ZStack {
            Circle()
                .fill(EQBandColor.color(band.index))
            Circle()
                .stroke(Color.white.opacity(isSelected ? 0.95 : 0.45), lineWidth: isSelected ? 2 : 1)
            Text("\(band.index + 1)")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundColor(.black.opacity(0.75))
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: .black.opacity(0.25), radius: 1.5, x: 0, y: 0.5)
        // Generous hit target around the dot
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hoveredBand = band.index
            } else if hoveredBand == band.index {
                hoveredBand = nil
            }
        }
        .gesture(dragGesture(band.index, scale: scale))
        .contextMenu {
            ForEach(FilterType.allCases, id: \.self) { type in
                Button {
                    presetManager.updateBandFilterType(index: band.index, filterType: type)
                } label: {
                    if type == band.filterType {
                        Label(type.displayName, systemImage: "checkmark")
                    } else {
                        Text(type.displayName)
                    }
                }
            }
            Divider()
            Button("Remove Band") {
                presetManager.removeBand(index: band.index)
            }
        }
        .position(x: scale.x(forHz: band.frequencyHz), y: scale.y(forDb: band.nodeDb))
    }

    private func dragGesture(_ index: Int, scale: EQGraphScale) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if draggingBand != index {
                    draggingBand = index
                    lastDragTranslation = .zero
                    if presetManager.focusedBandIndex != index {
                        presetManager.setFocusedBand(index)
                    }
                }

                // Apply movement incrementally so toggling Shift mid-drag doesn't jump
                let factor = CGFloat(fineFactor())
                let dx = (value.translation.width - lastDragTranslation.width) * factor
                let dy = (value.translation.height - lastDragTranslation.height) * factor
                lastDragTranslation = value.translation
                guard dx != 0 || dy != 0 else { return }

                let x = scale.x(forHz: presetManager.currentFrequencies[index]) + dx
                presetManager.updateBandFrequency(index: index, frequencyHz: scale.hz(forX: x))

                if presetManager.currentFilterTypes[index].usesGain {
                    let gain = presetManager.currentBands[index] + scale.dbDelta(forDy: dy)
                    presetManager.updateBand(index: index, gainDb: gain)
                } else {
                    // No gain on pass/notch filters: vertical drag shapes the resonance instead
                    let q = presetManager.currentQFactors[index] * pow(2, Float(-dy) / 30)
                    presetManager.updateBandQ(index: index, qFactor: q)
                }
            }
            .onEnded { _ in
                draggingBand = nil
                lastDragTranslation = .zero
            }
    }

    private func readout(_ band: BandSnapshot, scale: EQGraphScale) -> some View {
        var parts = [EQFormat.frequency(band.frequencyHz)]
        if band.filterType.usesGain {
            parts.append(EQFormat.gain(band.gainDb))
        }
        parts.append("Q \(EQFormat.q(band.qFactor))")

        // Keep the label inside the graph: above the node, or below it near the top edge
        let x = min(max(scale.x(forHz: band.frequencyHz), 62), scale.size.width - 62)
        let nodeY = scale.y(forDb: band.nodeDb)
        let y = nodeY < 30 ? nodeY + 20 : nodeY - 20

        return Text(parts.joined(separator: "  "))
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(NSColor.windowBackgroundColor).opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(EQBandColor.color(band.index).opacity(0.7), lineWidth: 0.5)
            )
            .fixedSize()
            .position(x: x, y: y)
            .allowsHitTesting(false)
    }

    private func addBand(at location: CGPoint, scale: EQGraphScale) {
        let gain = (scale.db(forY: location.y) * 10).rounded() / 10
        if presetManager.addBand(frequencyHz: scale.hz(forX: location.x), gainDb: gain) == nil {
            // All bands in use
            NSSound.beep()
        }
    }

    // MARK: Drawing

    private func drawGrid(in context: inout GraphicsContext, scale: EQGraphScale) {
        let size = scale.size
        let gridColor = Color(NSColor.separatorColor)

        for hz in Self.gridFrequencies {
            let x = scale.x(forHz: hz)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            let isDecade = hz == 100 || hz == 1000 || hz == 10000
            context.stroke(line, with: .color(gridColor.opacity(isDecade ? 0.45 : 0.2)), lineWidth: 0.5)
        }

        for db in Self.gridDb {
            let y = scale.y(forDb: db)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(gridColor.opacity(db == 0 ? 0.7 : 0.2)), lineWidth: db == 0 ? 1 : 0.5)

            if db != 0 {
                let label = Text(db > 0 ? "+\(Int(db))" : "\(Int(db))")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                context.draw(label, at: CGPoint(x: 3, y: y - 1), anchor: .bottomLeading)
            }
        }
    }

    private func drawCurves(
        in context: inout GraphicsContext,
        scale: EQGraphScale,
        bands: [BandSnapshot],
        selected: Int?
    ) {
        guard !bands.isEmpty else { return }

        let size = scale.size
        let steps = max(Int(size.width / 2), 2)
        let xs: [CGFloat] = (0...steps).map { size.width * CGFloat($0) / CGFloat(steps) }
        let freqs: [Double] = xs.map { Double(scale.hz(forX: $0)) }
        let zeroY = scale.y(forDb: 0)

        // Clamp so notches and pass-band slopes stay drawable
        let limit = Double(EQGraphScale.displayDb) + 3
        func path(for dbs: [Double]) -> Path {
            var path = Path()
            for (k, db) in dbs.enumerated() {
                let point = CGPoint(x: xs[k], y: scale.y(forDb: Float(min(max(db, -limit), limit))))
                if k == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            return path
        }
        func area(for curve: Path) -> Path {
            var area = curve
            area.addLine(to: CGPoint(x: size.width, y: zeroY))
            area.addLine(to: CGPoint(x: 0, y: zeroY))
            area.closeSubpath()
            return area
        }

        let responses: [(index: Int, dbs: [Double])] = bands.map { band in
            let coeffs = band.coeffs
            return (band.index, freqs.map { EQResponse.magnitudeDb(coeffs, at: $0) })
        }

        // The selected band's own contribution
        if let selected, let response = responses.first(where: { $0.index == selected }) {
            let color = EQBandColor.color(selected)
            let curve = path(for: response.dbs)
            context.fill(area(for: curve), with: .color(color.opacity(0.2)))
            context.stroke(curve, with: .color(color.opacity(0.8)), lineWidth: 1)
        }

        // Combined response of all bands (cascaded biquads add in dB)
        var total = [Double](repeating: 0, count: freqs.count)
        for response in responses {
            for k in total.indices {
                total[k] += response.dbs[k]
            }
        }
        let curve = path(for: total)
        context.fill(area(for: curve), with: .color(Color.accentColor.opacity(0.12)))
        context.stroke(curve, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.75, lineJoin: .round))
    }
}

struct FrequencyAxisLabels: View {
    private struct AxisLabel {
        let hz: Float
        let text: String
    }

    private static let labels: [AxisLabel] = [
        AxisLabel(hz: 50, text: "50"),
        AxisLabel(hz: 100, text: "100"),
        AxisLabel(hz: 200, text: "200"),
        AxisLabel(hz: 500, text: "500"),
        AxisLabel(hz: 1000, text: "1k"),
        AxisLabel(hz: 2000, text: "2k"),
        AxisLabel(hz: 5000, text: "5k"),
        AxisLabel(hz: 10000, text: "10k"),
    ]

    var body: some View {
        GeometryReader { geometry in
            let scale = EQGraphScale(size: geometry.size)
            ForEach(Self.labels, id: \.hz) { label in
                Text(label.text)
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                    .fixedSize()
                    .position(x: scale.x(forHz: label.hz), y: geometry.size.height / 2)
            }
        }
    }
}

// MARK: - Band Inspector

/// Exact controls for the selected band: type, frequency, gain, Q
struct BandInspector: View {
    let bandIndex: Int
    @ObservedObject private var presetManager = PresetManager.shared

    var body: some View {
        let type = presetManager.currentFilterTypes[bandIndex]
        let frequency = presetManager.currentFrequencies[bandIndex]
        let gain = presetManager.currentBands[bandIndex]
        let q = presetManager.currentQFactors[bandIndex]

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(EQBandColor.color(bandIndex))
                    .frame(width: 9, height: 9)

                Text("Band \(bandIndex + 1)")
                    .font(.system(size: 11, weight: .medium))

                Spacer()

                Picker(
                    "",
                    selection: Binding(
                        get: { type },
                        set: { presetManager.updateBandFilterType(index: bandIndex, filterType: $0) }
                    )
                ) {
                    ForEach(FilterType.allCases, id: \.self) { filterType in
                        Text(filterType.displayName).tag(filterType)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()

                Button {
                    presetManager.removeBand(index: bandIndex)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove band")
            }

            HStack(spacing: 6) {
                ScrubField(
                    label: "Freq",
                    value: EQFormat.frequency(frequency),
                    onScrub: { dx in
                        // 60 points per octave
                        presetManager.updateBandFrequency(
                            index: bandIndex,
                            frequencyHz: presetManager.currentFrequencies[bandIndex] * pow(2, dx / 60)
                        )
                    },
                    onCommit: { text in
                        if let hz = EQFormat.parseFrequency(text) {
                            presetManager.updateBandFrequency(index: bandIndex, frequencyHz: hz)
                        }
                    }
                )

                ScrubField(
                    label: "Gain",
                    value: type.usesGain ? EQFormat.gain(gain) : "—",
                    isEnabled: type.usesGain,
                    onScrub: { dx in
                        presetManager.updateBand(index: bandIndex, gainDb: presetManager.currentBands[bandIndex] + dx * 0.1)
                    },
                    onCommit: { text in
                        if let db = EQFormat.parseNumber(text) {
                            presetManager.updateBand(index: bandIndex, gainDb: db)
                        }
                    }
                )

                ScrubField(
                    label: "Q",
                    value: EQFormat.q(q),
                    onScrub: { dx in
                        presetManager.updateBandQ(
                            index: bandIndex,
                            qFactor: presetManager.currentQFactors[bandIndex] * pow(2, dx / 80)
                        )
                    },
                    onCommit: { text in
                        if let value = EQFormat.parseNumber(text) {
                            presetManager.updateBandQ(index: bandIndex, qFactor: value)
                        }
                    }
                )
            }

            Text("Drag nodes to move · scroll for Q · hold ⇧ for fine control")
                .font(.system(size: 9))
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

/// A value you can drag horizontally to adjust, or click to type
struct ScrubField: View {
    let label: String
    let value: String
    var isEnabled: Bool = true
    let onScrub: (Float) -> Void
    let onCommit: (String) -> Void

    @State private var isEditing = false
    @State private var draft = ""
    @State private var lastDragX: CGFloat = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.secondary)

            if isEditing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .focused($fieldFocused)
                    .onSubmit { commit() }
                    .onExitCommand { isEditing = false }
                    .onChange(of: fieldFocused) { focused in
                        if !focused { commit() }
                    }
            } else {
                Text(value)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(isEnabled ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(NSColor.separatorColor).opacity(0.25))
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { gesture in
                    guard isEnabled, !isEditing else { return }
                    let dx = gesture.translation.width - lastDragX
                    lastDragX = gesture.translation.width
                    onScrub(Float(dx) * fineFactor())
                }
                .onEnded { _ in
                    lastDragX = 0
                }
        )
        .onTapGesture {
            guard isEnabled else { return }
            draft = value
            isEditing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                fieldFocused = true
            }
        }
        .help(isEnabled ? "Drag to adjust, click to type" : "")
    }

    private func commit() {
        guard isEditing else { return }
        isEditing = false
        onCommit(draft)
    }
}
