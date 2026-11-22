import Combine
import Foundation
import QuartzCore

/// Turns one position per second (GPS or a replayed trip) into a position per screen frame for the
/// map, so the marker and the camera glide instead of jumping. The maths lives in MotionSmoother.
final class Motion: NSObject, ObservableObject {
    @Published private(set) var point: TrackPoint?
    /// Trip seconds per real second: 1 for GPS, the replay tempo during a replay.
    var rate = 1.0

    private var smoother = MotionSmoother()
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?

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
        link?.invalidate()
        link = nil
        lastTimestamp = nil
        guard running else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        // Real elapsed time, so a dropped frame makes one bigger step instead of slowing the motion.
        let dt = lastTimestamp.map { min(0.25, max(0, link.timestamp - $0)) } ?? 0
        lastTimestamp = link.timestamp
        if let next = smoother.step(dt * rate) { point = next }
    }
}
