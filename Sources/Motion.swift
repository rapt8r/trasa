import Combine
import Foundation

/// Turns one position per second (GPS or a replayed trip) into a position per frame for the map,
/// so the marker and the camera glide instead of jumping. The maths lives in MotionSmoother.
final class Motion: ObservableObject {
    static let frameRate = 30.0

    @Published private(set) var point: TrackPoint?
    /// Trip seconds per real second: 1 for GPS, the replay tempo during a replay.
    var rate = 1.0

    private var smoother = MotionSmoother()
    private var timer: Timer?
    private var lastTick = Date()

    /// A new fix, or nil to forget the current position (the next fix then appears without a glide).
    func feed(_ fix: TrackPoint?) {
        if let fix {
            smoother.feed(fix)
        } else {
            smoother = MotionSmoother()
            point = nil
        }
    }

    /// Frames are only produced while the app is on screen.
    func setRunning(_ running: Bool) {
        timer?.invalidate()
        timer = nil
        guard running else { return }
        lastTick = Date()
        let timer = Timer(timeInterval: 1 / Self.frameRate, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = Date()
        let dt = min(0.25, now.timeIntervalSince(lastTick))
        lastTick = now
        if let next = smoother.step(dt * rate) { point = next }
    }
}
