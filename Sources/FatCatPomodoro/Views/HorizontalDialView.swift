import SwiftUI
import AppKit

struct HorizontalDialView: View {
    @Binding var value: Int // in minutes
    let range: ClosedRange<Int>
    let title: String
    /// Sentinel value rendered as an ∞ tick left of the range (open-ended session).
    var infinityValue: Int? = nil

    @State private var internalId: Int?
    @State private var dragStartIndex: Int?
    private let tickSpacing: CGFloat = 16
    private let majorTickHeight: CGFloat = 20
    private let minorTickHeight: CGFloat = 10
    
    var body: some View {
        VStack(spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .black))
                .foregroundColor(.white.opacity(0.3))
                .tracking(1)
                .padding(.bottom, 4)
            
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .bottom, spacing: 0) {
                            ForEach(allValues, id: \.self) { i in
                                if i == infinityValue {
                                    // Composite element: ∞ glyph centered so viewAligned
                                    // snapping lands on it, ghost minor ticks filling a full
                                    // major-step gap toward the first real value.
                                    HStack(alignment: .bottom, spacing: 0) {
                                        Color.clear.frame(width: tickSpacing * 4, height: 1)
                                        tickView(for: i)
                                        ForEach(0..<4, id: \.self) { _ in ghostTick }
                                    }
                                    .id(i)
                                } else {
                                    tickView(for: i)
                                        .id(i)
                                }
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .contentMargins(.horizontal, max(0, (geo.size.width - tickSpacing) / 2), for: .scrollContent)
                    .scrollTargetBehavior(.viewAligned)
                    .scrollPosition(id: $internalId)
                    // Mouse support: ScrollView only pans via trackpad swipes, so mice
                    // need explicit handling — click-drag moves the tape under the
                    // fixed pointer, and a discrete wheel steps one minute per notch.
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { g in
                                if dragStartIndex == nil { dragStartIndex = index(of: internalId ?? value) }
                                let steps = Int((-g.translation.width / tickSpacing).rounded())
                                select(index: (dragStartIndex ?? 0) + steps)
                            }
                            .onEnded { _ in dragStartIndex = nil }
                    )
                    .background(MouseWheelCatcher { step in
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                            select(index: index(of: internalId ?? value) + step)
                        }
                    })
                    .overlay(alignment: .center) {
                        let current = internalId ?? value
                        let onMajor = current % 5 == 0 || current == infinityValue
                        VStack(spacing: 4) {
                            Text(current == infinityValue ? "∞" : "\(current)")
                                .font(.system(size: 18, weight: .black, design: .rounded))
                                .foregroundColor(.orange)
                                .shadow(color: Color.orange.opacity(0.4), radius: 6)
                                .offset(y: -18)

                            Capsule()
                                .fill(Color.orange)
                                .frame(width: 2, height: majorTickHeight + 8)
                                .opacity(onMajor ? 0 : 1)
                                .animation(.easeInOut(duration: 0.12), value: onMajor)
                        }
                        .offset(y: 6)
                    }
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.2),
                                .init(color: .black, location: 0.8),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    }
                    .onAppear {
                        internalId = value
                        proxy.scrollTo(value, anchor: .center)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            proxy.scrollTo(value, anchor: .center)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            proxy.scrollTo(value, anchor: .center)
                        }
                    }
                    .onChange(of: value) { _, newValue in
                        if internalId != newValue {
                            internalId = newValue
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                proxy.scrollTo(newValue, anchor: .center)
                            }
                        }
                    }
                    .onChange(of: internalId) { _, newId in
                        if let newId = newId, newId != value {
                            value = newId
                            if newId % 5 == 0 {
                                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                            } else {
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                            }
                        }
                    }
                }
            }
            .frame(height: 56)
        }
    }

    private func tickView(for i: Int) -> some View {
        let isMajor = (i % 5 == 0) || (i == range.lowerBound) || (i == infinityValue)
        return VStack(spacing: 4) {
            Rectangle()
                .fill(isMajor ? Color.white : Color.white.opacity(0.4))
                .frame(width: isMajor ? 2 : 1,
                       height: isMajor ? majorTickHeight : minorTickHeight)

            if isMajor {
                Text(i == infinityValue ? "∞" : "\(i)")
                    .font(.system(size: 10, weight: i == (internalId ?? value) ? .black : .bold))
                    .foregroundColor(i == (internalId ?? value) ? .orange : .white.opacity(0.7))
                    .fixedSize()
            } else {
                Text("")
                    .font(.system(size: 10))
                    .fixedSize()
            }
        }
        .frame(width: tickSpacing)
        .scaleEffect(i == (internalId ?? value) ? 1.2 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: internalId)
    }

    /// Non-selectable minor tick matching the tape texture between real values.
    private var ghostTick: some View {
        VStack(spacing: 4) {
            Rectangle()
                .fill(Color.white.opacity(0.4))
                .frame(width: 1, height: minorTickHeight)
            Text("")
                .font(.system(size: 10))
                .fixedSize()
        }
        .frame(width: tickSpacing)
    }

    // All selectable tick values, the optional ∞ sentinel first. Drag/wheel step
    // through this array by index so crossing the ∞ ↔ lowerBound boundary works.
    private var allValues: [Int] {
        (infinityValue.map { [$0] } ?? []) + Array(range)
    }

    private func index(of value: Int) -> Int {
        allValues.firstIndex(of: value) ?? 0
    }

    private func select(index: Int) {
        let clamped = min(allValues.count - 1, max(0, index))
        let newValue = allValues[clamped]
        if newValue != internalId {
            internalId = newValue // scrollPosition binding scrolls the tape; onChange syncs `value`
        }
    }
}

/// Catches discrete mouse-wheel events over the dial via a local event monitor.
/// Trackpad scrolls (precise deltas) pass through untouched so the ScrollView
/// keeps its native momentum + snap behavior; the view itself is hit-test
/// transparent and only serves as a frame reference.
private struct MouseWheelCatcher: NSViewRepresentable {
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> WheelCatcherView {
        let view = WheelCatcherView()
        view.onStep = onStep
        return view
    }

    func updateNSView(_ nsView: WheelCatcherView, context: Context) {
        nsView.onStep = onStep
    }

    final class WheelCatcherView: NSView {
        var onStep: ((Int) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                    guard let self, event.window === self.window,
                          !event.hasPreciseScrollingDeltas else { return event }
                    let point = self.convert(event.locationInWindow, from: nil)
                    guard self.bounds.contains(point) else { return event }
                    let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : -event.scrollingDeltaX
                    guard delta != 0 else { return event }
                    self.onStep?(delta > 0 ? 1 : -1) // wheel up → more minutes
                    return nil
                }
            } else if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
