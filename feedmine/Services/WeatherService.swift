import Foundation
import CoreLocation

@MainActor
final class WeatherService {
    static let shared = WeatherService()
    private var lastFetch: Date?
    private let cacheInterval: TimeInterval = 900

    private init() {}

    func fetch() async {
        if let last = lastFetch, Date().timeIntervalSince(last) < cacheInterval { return }
        let location = await currentLocation()
        guard let lat = location?.coordinate.latitude,
              let lon = location?.coordinate.longitude else { return }

        let urlStr = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m,apparent_temperature&daily=temperature_2m_max,temperature_2m_min,uv_index_max&timezone=auto&forecast_days=1"
        guard let url = URL(string: urlStr) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
            AppContext.shared.temperature = decoded.current.temperature2m
            AppContext.shared.feelsLike = decoded.current.apparentTemperature
            AppContext.shared.humidity = decoded.current.relativeHumidity2m
            AppContext.shared.windSpeed = decoded.current.windSpeed10m
            AppContext.shared.weatherCondition = weatherCodeToCondition(decoded.current.weatherCode)
            AppContext.shared.temperatureFeel = TemperatureFeel.from(f: decoded.current.temperature2m)
            if let daily = decoded.daily {
                AppContext.shared.hiTemp = daily.temperature2mMax.first
                AppContext.shared.loTemp = daily.temperature2mMin.first
                AppContext.shared.uvIndex = daily.uvIndexMax.first.map { Int($0) }
            }
            lastFetch = Date()
        } catch {
            // Silent — greeting adapts
        }
    }

    private func currentLocation() async -> CLLocation? {
        let manager = CLLocationManager()
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
            return nil
        }
        guard manager.authorizationStatus == .authorizedWhenInUse
           || manager.authorizationStatus == .authorizedAlways else { return nil }
        return manager.location
    }

    private func weatherCodeToCondition(_ code: Int) -> WeatherCondition {
        switch code {
        case 0: .clear; case 1,2,3: .partlyCloudy; case 45,48: .fog
        case 51,53,55: .drizzle; case 56,57: .sleet; case 61,63,65: .rain
        case 66,67: .sleet; case 71,73,75: .snow; case 77: .snow
        case 80,81,82: .heavyRain; case 85,86: .snow
        case 95: .thunderstorm; case 96,99: .hail; default: .partlyCloudy
        }
    }

    private struct OpenMeteoResponse: Codable {
        let current: Current; let daily: Daily?
        struct Current: Codable {
            let temperature2m: Double; let relativeHumidity2m: Double
            let weatherCode: Int; let windSpeed10m: Double; let apparentTemperature: Double
            enum CodingKeys: String, CodingKey {
                case temperature2m="temperature_2m"; case relativeHumidity2m="relative_humidity_2m"
                case weatherCode="weather_code"; case windSpeed10m="wind_speed_10m"
                case apparentTemperature="apparent_temperature"
            }
        }
        struct Daily: Codable {
            let temperature2mMax: [Double]; let temperature2mMin: [Double]; let uvIndexMax: [Double]
            enum CodingKeys: String, CodingKey {
                case temperature2mMax="temperature_2m_max"; case temperature2mMin="temperature_2m_min"
                case uvIndexMax="uv_index_max"
            }
        }
    }
}
