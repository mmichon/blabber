import Foundation
import CoreLocation

@MainActor
final class LocationService: NSObject, ObservableObject {
    static let shared = LocationService()

    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func fetchLocationTitle() async -> String {
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways,
              let location = manager.location
        else {
            return formattedDateTitle()
        }
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            return titleFrom(placemarks.first) ?? formattedDateTitle()
        } catch {
            return formattedDateTitle()
        }
    }

    private func titleFrom(_ placemark: CLPlacemark?) -> String? {
        guard let p = placemark else { return nil }
        if let name = p.name, !name.isEmpty, name != p.thoroughfare {
            return "Near \(name)"
        }
        if let area = p.subLocality { return "Near \(area)" }
        if let city = p.locality, let state = p.administrativeArea {
            return "\(city), \(state)"
        }
        return p.locality ?? p.administrativeArea
    }

    private func formattedDateTitle() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d 'at' h:mm a"
        return f.string(from: Date())
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorizationStatus = manager.authorizationStatus
            if manager.authorizationStatus == .authorizedWhenInUse ||
               manager.authorizationStatus == .authorizedAlways {
                self.manager.startUpdatingLocation()
            }
        }
    }
}
