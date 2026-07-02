import CoreLocation
import Dependencies
import DependenciesMacros
import Foundation
import MapKit

/// A plain, `Sendable` lat/lng pair — `CLLocationCoordinate2D` isn't `Sendable`, so the client
/// vends this across concurrency boundaries instead.
public struct Coordinate: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// First-party location + drive-time intelligence, Apple-only (Core Location + MapKit; no
/// third-party APIs). Used by the meal-plan place-search sheet (region-bias suggestions) and the
/// Today dinner card (traffic-aware ETA). Everything degrades to `nil`/no-op when the user hasn't
/// granted When-In-Use — the dashboard and search stay fully functional without location.
@DependencyClient
public struct LocationClient: Sendable {
    /// The current When-In-Use authorization state (safe to read from any thread).
    public var authorizationStatus: @Sendable () -> CLAuthorizationStatus = { .notDetermined }
    /// Prompt for When-In-Use authorization. No-op once already determined.
    public var requestWhenInUseAuthorization: @Sendable () -> Void
    /// One-shot current location, or nil when denied/undetermined or the fix fails.
    public var currentLocation: @Sendable () async -> Coordinate?
    /// Traffic-aware automobile ETA (whole minutes, ≥1) from the device's current location to the
    /// destination for `departureDate`, or nil when location is unavailable or MKDirections fails.
    public var driveTimeMinutes: @Sendable (_ toLatitude: Double, _ toLongitude: Double, _ departureDate: Date) async -> Int?
}

extension LocationClient: DependencyKey {
    public static let liveValue = LocationClient(
        authorizationStatus: { LocationCoordinator.cachedStatus() },
        requestWhenInUseAuthorization: {
            Task { await LocationCoordinator.shared.requestAuthorization() }
        },
        currentLocation: { await LocationCoordinator.shared.currentLocation() },
        driveTimeMinutes: { toLatitude, toLongitude, departureDate in
            guard let origin = await LocationCoordinator.shared.currentLocation() else { return nil }
            return await eta(
                from: origin, toLatitude: toLatitude, toLongitude: toLongitude,
                departureDate: departureDate
            )
        }
    )

    public static let previewValue = LocationClient(
        authorizationStatus: { .authorizedWhenInUse },
        requestWhenInUseAuthorization: {},
        currentLocation: { Coordinate(latitude: 35.5951, longitude: -82.5515) },
        driveTimeMinutes: { _, _, _ in 12 }
    )

    /// Traffic-aware ETA via MKDirections. Returns nil on any failure (no route, offline, sim
    /// without a road-network fix) so callers simply hide the drive line.
    static func eta(from origin: Coordinate, toLatitude: Double, toLongitude: Double, departureDate: Date) async -> Int? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude)
        ))
        request.destination = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: toLatitude, longitude: toLongitude)
        ))
        request.transportType = .automobile
        request.departureDate = departureDate
        let directions = MKDirections(request: request)
        guard let response = try? await directions.calculate(), let route = response.routes.first else {
            return nil
        }
        return max(1, Int((route.expectedTravelTime / 60).rounded()))
    }
}

/// Bridges `CLLocationManager`'s delegate callbacks into `async`. Confined to the main actor so the
/// manager is created — and its delegate callbacks delivered — on the main run loop (Core Location
/// silently drops callbacks for managers created on a thread without a running run loop). Uses
/// `startUpdatingLocation` + a cached-location fast path + a timeout, which is far more reliable on
/// the simulator than the one-shot `requestLocation`.
@MainActor
private final class LocationCoordinator: NSObject, CLLocationManagerDelegate {
    static let shared = LocationCoordinator()

    private let manager = CLLocationManager()
    private var continuations: [CheckedContinuation<Coordinate?, Never>] = []
    private var timeoutTask: Task<Void, Never>?

    // Nonisolated cache so the sync `authorizationStatus` endpoint can read it from any thread.
    nonisolated private static let statusLock = NSLock()
    nonisolated(unsafe) private static var _cachedStatus: CLAuthorizationStatus = .notDetermined

    nonisolated static func cachedStatus() -> CLAuthorizationStatus {
        statusLock.lock(); defer { statusLock.unlock() }
        return _cachedStatus
    }

    nonisolated private static func setCachedStatus(_ status: CLAuthorizationStatus) {
        statusLock.lock(); _cachedStatus = status; statusLock.unlock()
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        Self.setCachedStatus(manager.authorizationStatus)
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func currentLocation() async -> Coordinate? {
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return nil }
        // Fast path: a recent cached fix (populated once updates have started).
        if let loc = manager.location {
            return Coordinate(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
        }
        return await withCheckedContinuation { cont in
            continuations.append(cont)
            manager.startUpdatingLocation()
            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                self?.resumeAll(with: nil)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        LocationCoordinator.setCachedStatus(manager.authorizationStatus)
    }

    // CL delivers these on the main run loop (the manager was created on main), so it's safe to
    // assume main-actor isolation to touch the manager + continuation state.
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let coord = Coordinate(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude)
        MainActor.assumeIsolated { self.resumeAll(with: coord) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient errors are common while a fix warms up; let the timeout decide, unless there are
        // no active waiters.
        MainActor.assumeIsolated {
            if self.continuations.isEmpty { manager.stopUpdatingLocation() }
        }
    }

    private func resumeAll(with value: Coordinate?) {
        manager.stopUpdatingLocation()
        timeoutTask?.cancel()
        timeoutTask = nil
        let pending = continuations
        continuations.removeAll()
        for cont in pending { cont.resume(returning: value) }
    }
}

public extension DependencyValues {
    var location: LocationClient {
        get { self[LocationClient.self] }
        set { self[LocationClient.self] = newValue }
    }
}
