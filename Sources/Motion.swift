import Combine
import CoreLocation
import CoreMotion
import Foundation
import QuartzCore

/// Sideways and forward-back acceleration felt in the car, for display.
final class GMeter: ObservableObject {
    @Published var value = 0.0 // g, smoothed
}

/// Turns one position per second (GPS or a replayed trip) into a position per screen frame for the
/// map, so the marker and the camera glide instead of jumping. The maths lives in MotionSmoother.
///
/// Between GPS fixes it also listens to the phone's own sensors:
/// - gyroscope: how fast the car is turning, so the marker follows a bend instead of cutting it;
/// - compass: which way the car points while it stands still, when GPS has no course;
/// - accelerometer: the g-force shown in the sheet.
final class Motion: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let yawDeadband = 0.5          // deg/s; below this the gyroscope is reading noise
    static let maxCompassError = 35.0     // degrees; a worse compass reading is ignored
    static let gSmoothing = 0.3           // s
    static let gPublishInterval = 0.25    // s

    @Published private(set) var point: TrackPoint?
    /// Trip seconds per real second: 1 for GPS, the replay tempo during a replay.
    var rate = 1.0
    /// Off during a replay: the phone on the desk says nothing about the recorded drive.
    var useSensors = true
    let gMeter = GMeter()

    private var smoother = MotionSmoother()
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private let motionManager = CMMotionManager()
    private let headingManager = CLLocationManager()
    private var compass: Double?
    private var smoothedG = 0.0
    private var sinceGPublish = 0.0

    /// A new fix, or nil to forget the current position (the next fix then appears without a glide).
    func feed(_ fix: TrackPoint?) {
        if let fix {
            smoother.feed(fix)
        } else {
            smoother = MotionSmoother()
            point = nil
        }
    }

    /// Frames and sensor readings are only produced while the app is on screen.
    func setRunning(_ running: Bool) {
        link?.invalidate()
        link = nil
        lastTimestamp = nil
        motionManager.stopDeviceMotionUpdates()
        headingManager.stopUpdatingHeading()
        guard running else { return }

        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 1.0 / 60
            motionManager.startDeviceMotionUpdates()
        }
        headingManager.delegate = self
        headingManager.headingFilter = 1
        headingManager.startUpdatingHeading()

        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        // Real elapsed time, so a dropped frame makes one bigger step instead of slowing the motion.
        let dt = lastTimestamp.map { min(0.25, max(0, link.timestamp - $0)) } ?? 0
        lastTimestamp = link.timestamp

        var yawRate: Double?
        var heading: Double?
        if useSensors {
            heading = compass
            if let m = motionManager.deviceMotion {
                let g = m.gravity, w = m.rotationRate, a = m.userAcceleration
                // Rotation about the vertical axis, clockwise seen from above, whatever way the phone is mounted.
                let turn = (w.x * g.x + w.y * g.y + w.z * g.z) * 180 / Double.pi
                yawRate = abs(turn) < Self.yawDeadband ? 0 : turn
                // Acceleration with its vertical part (bumps) removed.
                let vertical = a.x * g.x + a.y * g.y + a.z * g.z
                let hx = a.x - vertical * g.x, hy = a.y - vertical * g.y, hz = a.z - vertical * g.z
                let horizontal = (hx * hx + hy * hy + hz * hz).squareRoot()
                smoothedG += (horizontal - smoothedG) * (1 - exp(-dt / Self.gSmoothing))
            }
        } else {
            smoothedG = 0
        }

        sinceGPublish += dt
        if sinceGPublish >= Self.gPublishInterval {
            sinceGPublish = 0
            if abs(gMeter.value - smoothedG) > 0.005 { gMeter.value = smoothedG }
        }

        if let next = smoother.step(dt * rate, yawRate: yawRate, compass: heading) { point = next }
    }

    // MARK: CLLocationManagerDelegate (compass only)

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0, newHeading.headingAccuracy <= Self.maxCompassError else {
            compass = nil
            return
        }
        compass = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        false // no figure-of-eight prompt in the car
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Heading is optional; GPS course takes over as soon as the car moves.
    }
}
