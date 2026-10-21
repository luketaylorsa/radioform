import SwiftUI
import AppKit

struct VerticalSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let isFocused: Bool
    let onDoubleTap: () -> Void

    private let normalKnobSize: CGFloat = 16
    private let focusedKnobSize: CGFloat = 22

    // While dragging, if the user moves the cursor horizontally beyond this threshold, the dB levels will be adjusted more precisely
    private let preciseThresholdX: Float = 50
    // Exit precise mode below this threshold (hysteresis prevents flickering near boundary)
    private let preciseExitThresholdX: Float = 35
    // Multiplier that allows for fine-grained dB adjustments
    private let preciseFactor: Float = 0.05

    // Remember the drag Y value so we can maintain the slider position when shifting to precise mode
    @State private var prevDragY: CGFloat? = nil

    // Used for the knob border to reflect the current dragging mode
    @State private var isDragging: Bool = false
    @State private var isPreciseDrag: Bool = false

    private var knobSize: CGFloat {
        isFocused ? focusedKnobSize : normalKnobSize
    }

    private var knobDisplayText: String {
        if value >= 0 {
            return String(format: "+%.1f", value)
        } else {
            return String(format: "%.1f", value)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // Track background
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(NSColor.separatorColor))
                    .frame(width: 4)

                // Center line (0 dB)
                let centerY = geometry.size.height / 2
                Rectangle()
                    .fill(Color(NSColor.tertiaryLabelColor))
                    .frame(width: 20, height: 1)
                    .position(x: geometry.size.width / 2, y: centerY)

                // Filled portion (from center to knob)
                let normalizedValue = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                let knobY = geometry.size.height * (1 - CGFloat(normalizedValue))

                if value != 0 {
                    let fillHeight = abs(knobY - centerY)
                    let fillY = min(knobY, centerY)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor)
                        .frame(width: 4, height: fillHeight)
                        .position(x: geometry.size.width / 2, y: fillY + fillHeight / 2)
                }

                // Knob
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(NSColor.controlBackgroundColor),
                                    Color(NSColor.controlBackgroundColor).opacity(0.9)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay(
                            Circle()
                                .stroke(
                                    (isFocused
                                        ? isDragging
                                            ? Color.white
                                            : Color.accentColor.opacity(0.6)
                                        : Color(NSColor.separatorColor).opacity(0.8)),
                                    style: StrokeStyle(
                                        lineWidth: isFocused ? 1 : 0.5,

                                        // Dotted border indicates precise dragging mode
                                        dash: isDragging && isPreciseDrag ? [2, 2] : []
                                    )
                                )
                        )

                    // dB text inside focused knob
                    if isFocused {
                        Text(knobDisplayText)
                            .font(.system(size: 7, weight: .medium, design: .rounded))
                            .foregroundColor(.primary.opacity(0.8))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            // Reduce horizontal text movement when dragging
                            .monospacedDigit()
                    }
                }
                .frame(width: knobSize, height: knobSize)
                .shadow(color: .black.opacity(0.15), radius: 1.5, x: 0, y: 0.5)
                .position(
                    x: geometry.size.width / 2,
                    y: knobY
                )
                .onTapGesture(count: 2) {
                    onDoubleTap()
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { gesture in
                            let rangeSpan = range.upperBound - range.lowerBound
                            let knobCenterX = Float(knobSize / 2)
                            let mouseDistanceX = abs(Float(gesture.location.x) - knobCenterX)

                            isDragging = true
                            if mouseDistanceX > preciseThresholdX {
                                isPreciseDrag = true
                            } else if mouseDistanceX < preciseExitThresholdX {
                                isPreciseDrag = false
                            }
                            let multiplier: Float = isPreciseDrag ? preciseFactor : 1

                            let deltaY = Float(gesture.translation.height - (prevDragY ?? gesture.translation.height))
                            let progress = -deltaY / Float(geometry.size.height)
                            let valueIncrement = progress * rangeSpan * multiplier
                            value = min(max(range.lowerBound, value + valueIncrement), range.upperBound)

                            prevDragY = gesture.translation.height
                        }
                        .onEnded { _ in
                            isDragging = false
                            isPreciseDrag = false
                            prevDragY = nil
                        }
                )
            }
        }
    }
}

// MARK: - Scroll Wheel Receiver (macOS)

struct ScrollWheelReceiver: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollWheelNSView {
        ScrollWheelNSView(onScroll: onScroll)
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.onScroll = onScroll
    }

    class ScrollWheelNSView: NSView {
        var onScroll: (CGFloat) -> Void

        init(onScroll: @escaping (CGFloat) -> Void) {
            self.onScroll = onScroll
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func scrollWheel(with event: NSEvent) {
            onScroll(event.deltaY)
        }
    }
}
