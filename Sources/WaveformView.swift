import Cocoa

/// A compact, Siri-style equalizer: a row of rounded bars that breathe gently
/// while idle and swell with the live microphone level. Driven by a ~30fps
/// timer so the motion stays smooth and organic.
final class WaveformView: NSView {

    /// Target audio level, 0…1. Set live from the dictation manager.
    var level: CGFloat = 0

    /// Bar color (defaults to the app's brand purple).
    var color: NSColor = NSColor(srgbRed: 0.49, green: 0.40, blue: 0.95, alpha: 1)

    enum Alignment { case center, leading }
    /// Where the bar group sits horizontally. `.leading` reads as a track
    /// flowing out from the record button.
    var alignment: Alignment = .center

    private let barCount = 18
    private let barWidth: CGFloat = 4
    private let barSpacing: CGFloat = 5
    private let minBar: CGFloat = 3
    private let maxBarHeight: CGFloat = 26

    private var displayLevel: CGFloat = 0
    private var phase: CGFloat = 0
    private var timer: Timer?

    override var isFlipped: Bool { false }
    override var allowsVibrancy: Bool { true }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        level = 0
        displayLevel = 0
        needsDisplay = true
    }

    private func tick() {
        // Ease toward the target level, and keep a faint idle shimmer so the
        // bars never sit perfectly flat while listening.
        let idle: CGFloat = 0.12
        let target = max(level, idle)
        displayLevel += (target - displayLevel) * 0.3
        phase += 0.38
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
        var x = alignment == .leading ? 0 : (bounds.width - totalWidth) / 2
        let midY = bounds.midY
        let maxHeight = min(bounds.height, maxBarHeight)

        color.setFill()
        for i in 0..<barCount {
            // Phase-shifted sine per bar gives a lively, asymmetric ripple.
            let wave = sin(phase + CGFloat(i) * 0.55) * 0.5 + 0.5
            let weight = 0.4 + 0.6 * wave
            let height = max(minBar, minBar + (maxHeight - minBar) * displayLevel * weight)
            let rect = NSRect(x: x, y: midY - height / 2, width: barWidth, height: height)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + barSpacing
        }
    }
}
