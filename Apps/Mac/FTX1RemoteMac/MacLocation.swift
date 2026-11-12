import Combine
import CoreLocation
import Foundation

/// One location fix from this Mac (Wi-Fi based, usually tens of metres),
/// for Settings → APRS → Use This Mac's Location. Asks for permission the
/// first time; gives up 20 s after permission is settled.
@MainActor
final class MacLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var isLocating = false
    /// Why the last request failed, for the Settings row.
    @Published private(set) var problem: String?

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<(latitude: Double, longitude: Double)?, Never>?
    private var timeout: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func locate() async -> (latitude: Double, longitude: Double)? {
        guard continuation == nil else { return nil }
        problem = nil
        isLocating = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            proceed()
        }
    }

    /// Asks for permission or a fix, depending on where permission stands.
    private func proceed() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            finish(nil, problem: String(localized: "macLocation.denied"))
        default:
            // The 20 s start here, not while macOS's permission prompt waits
            // for an answer.
            timeout?.cancel()
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                self?.finish(nil, problem: String(localized: "macLocation.timedOut"))
            }
            manager.requestLocation()
        }
    }

    private func finish(_ coordinate: CLLocationCoordinate2D?, problem: String?) {
        let result = coordinate.map { (latitude: $0.latitude, longitude: $0.longitude) }
        timeout?.cancel()
        timeout = nil
        self.problem = problem
        isLocating = false
        continuation?.resume(returning: result)
        continuation = nil
    }

    // Delivered on the main thread (the manager was made there).
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard continuation != nil, manager.authorizationStatus != .notDetermined else { return }
            proceed()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.last?.coordinate
        MainActor.assumeIsolated {
            guard continuation != nil else { return }
            finish(coordinate, problem: coordinate == nil ? String(localized: "macLocation.failed") : nil)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        MainActor.assumeIsolated {
            guard continuation != nil else { return }
            finish(nil, problem: denied ? String(localized: "macLocation.denied") : String(localized: "macLocation.failed"))
        }
    }
}
