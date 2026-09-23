import AppKit
import SwiftUI

// The production view only needs these two settings cases.
enum ReadingPosition { case centered, nearTop }
enum ListeningMode { case wordTracking }
final class NotchSettings {
    static let shared = NotchSettings()
    let listeningMode = ListeningMode.wordTracking
    let selectedMicUID = ""
    let speechLocale = "en-US"
}

@main
struct ManualScrollChecks {
    static func main() {
        let positions: [Int: CGFloat] = [120: 900, 121: 900, 150: 940, 151: 940, 190: 980]
        assert(SpeechScrollView.wordProgress(at: 947, positions: positions, smooth: false, fallback: 0) == 150)
        assert(SpeechScrollView.wordProgress(at: 920, positions: positions, smooth: false, fallback: 0) == 120)
        assert(SpeechScrollView.wordProgress(at: 700, positions: positions, smooth: false, fallback: 0) == 120)
        assert(SpeechScrollView.wordProgress(at: 1200, positions: positions, smooth: false, fallback: 0) == 190)
        for smooth in [false, true] {
            assert(SpeechScrollView.wordProgress(at: 0, positions: [:], smooth: smooth, fallback: 42) == 42)
        }
        assert(SpeechScrollView.wordProgress(at: 110, positions: [3: 100, 4: 120], smooth: true, fallback: 0) == 3.5)

        let bounds: ClosedRange<CGFloat> = 15...6000
        assert(SpeechScrollView.clampedScrollOffset(-4500 + 2000, anchorY: 75, contentBounds: bounds) == -2500)
        assert(SpeechScrollView.clampedScrollOffset(10000, anchorY: 75, contentBounds: bounds) == 60)
        assert(SpeechScrollView.clampedScrollOffset(-10000, anchorY: 75, contentBounds: bounds) == -5925)
        assert(SpeechScrollView.clampedScrollOffset(0, anchorY: 300, contentBounds: 20...20) == 280)

        let view = ScrollWheelNSView()
        var deltas: [CGFloat] = []
        var endings = 0
        view.onScroll = { deltas.append($0) }
        view.onScrollEnd = { endings += 1 }

        // An ordinary wheel has no phases: coalesce events, then resume on idle.
        let wheel = event(delta: 3)
        assert(wheel.phase.isEmpty && wheel.momentumPhase.isEmpty)
        view.handleScroll(wheel)
        assert(deltas.last == wheel.scrollingDeltaY * 10)
        runLoop(for: 0.1)
        view.handleScroll(event(delta: 2))
        runLoop(for: 0.1)
        assert(endings == 0)
        runLoop(for: 0.15)
        assert(endings == 1)

        // Lift-off and momentum belong to one gesture, even across the idle timeout.
        let begin = event(delta: 4, phase: .began)
        assert(begin.phase.contains(.began) && begin.hasPreciseScrollingDeltas)
        view.handleScroll(begin)
        assert(deltas.last == begin.scrollingDeltaY)
        view.handleScroll(event(delta: 0, phase: .ended))
        runLoop(for: 0.08)
        view.handleScroll(event(delta: 3, momentum: .begin))
        view.handleScroll(event(delta: 1, momentum: CGMomentumScrollPhase(rawValue: 2)!))
        runLoop(for: 0.25)
        assert(endings == 1)
        let momentumEnd = event(delta: 0, momentum: .end)
        assert(momentumEnd.momentumPhase.contains(.ended))
        view.handleScroll(momentumEnd)
        assert(endings == 2)
        runLoop(for: 0.25)
        assert(endings == 2)

        view.handleScroll(begin)
        let cancelled = event(delta: 0, phase: .cancelled)
        assert(cancelled.phase.contains(.cancelled))
        view.handleScroll(cancelled)
        assert(endings == 3)
        view.handleScroll(cancelled)
        assert(endings == 3)

        // Removing the overlay must cancel its pending wheel timer.
        view.handleScroll(wheel)
        view.removeFromSuperview()
        runLoop(for: 0.25)
        assert(endings == 3)
        SpeechRecognizer.checkManualRewind()
        checkHostedFullscreenScroll()
        print("Manual scroll checks passed (position, bounds, wheel, momentum, cancellation, speech resume, fullscreen event delivery).")
    }

    private static func checkHostedFullscreenScroll() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let panel = NSPanel(
            contentRect: NSRect(x: -2000, y: -2000, width: 1024, height: 600),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        var starts = 0
        var positions: [Double] = []
        let content = SpeechScrollView(
            words: (0..<200).map { "word\($0)" }, highlightedCharCount: 0,
            font: .systemFont(ofSize: 39, weight: .semibold),
            onManualScroll: { scrolling, position in
                if scrolling { starts += 1 }
                if let position { positions.append(position) }
            },
            readingAnchorFraction: 0.1
        )
        .frame(width: 450, height: 480)
        .frame(width: 1024, height: 600)
        let hosting = NSHostingView(rootView: content)
        panel.contentView = hosting
        panel.orderFront(nil)
        defer { panel.orderOut(nil); panel.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        runLoop(for: 0.5)

        // Exercise the installed monitor and real SwiftUI layout, not handleScroll directly.
        app.sendEvent(WindowScrollEvent(window: panel, delta: -240))
        runLoop(for: 0.4)
        assert(starts == 1 && positions.count == 1, "Fullscreen must receive scroll events")
        assert(positions[0] > 0, "Scrolling must move away from the first line")

        app.sendEvent(WindowScrollEvent(window: panel, delta: 120))
        runLoop(for: 0.4)
        assert(starts == 2 && positions.count == 2)
        assert(positions[1] < positions[0], "Reverse scroll must select an earlier line")
    }

    private static func event(
        delta: Int32, phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase = .none
    ) -> NSEvent {
        let precise = phase != nil || momentum != .none
        let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
            wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0
        )!
        cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
        cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        return NSEvent(cgEvent: cgEvent)!
    }

    private static func runLoop(for seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}

// CGEvent-created NSEvents have no window. Supply one for in-process AppKit dispatch.
private final class WindowScrollEvent: NSEvent {
    private let target: NSWindow
    private let delta: CGFloat
    init(window: NSWindow, delta: CGFloat) {
        target = window
        self.delta = delta
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("Not used by this check") }
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { target }
    override var windowNumber: Int { target.windowNumber }
    override var locationInWindow: NSPoint { NSPoint(x: 512, y: 300) }
    override var scrollingDeltaY: CGFloat { delta }
    override var scrollingDeltaX: CGFloat { 0 }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var phase: NSEvent.Phase { [] }
    override var momentumPhase: NSEvent.Phase { [] }
}

// The runner joins this file to the unmodified recognizer to exercise its private matcher.
extension SpeechRecognizer {
    static func checkManualRewind() {
        let recognizer = SpeechRecognizer()
        let script = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima"
        let previousOffset = "alpha bravo charlie delta echo foxtrot ".count
        recognizer.updateText(script, preservingCharCount: previousOffset)
        recognizer.isManuallyScrolling = true
        recognizer.lastSpokenText = script // The recognition callback keeps this current.
        recognizer.matchCharacters(spoken: script)
        assert(recognizer.recognizedCharCount == previousOffset)
        assert(!recognizer.shouldDismiss && !recognizer.shouldAdvancePage)

        recognizer.isManuallyScrolling = false
        let rewindOffset = "alpha ".count
        recognizer.jumpTo(charOffset: rewindOffset)
        recognizer.matchCharacters(spoken: script)
        assert(recognizer.recognizedCharCount == rewindOffset)
        RunLoop.main.run(until: Date().addingTimeInterval(0.31))
        recognizer.matchCharacters(spoken: script)
        assert(recognizer.recognizedCharCount == rewindOffset)
        recognizer.matchCharacters(spoken: script + " bravo charlie")
        assert(recognizer.recognizedCharCount >= "alpha bravo charlie".count)
        assert(recognizer.recognizedCharCount < previousOffset)
        assert(!recognizer.shouldDismiss && !recognizer.shouldAdvancePage)
    }
}
