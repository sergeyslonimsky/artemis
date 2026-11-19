import CoreLocation
import Foundation
import FoundationModels
import MapKit

/// The device's location for tools, asked for only while the app is in use.
actor LocationProvider {
    static let shared = LocationProvider()

    enum LocationError: LocalizedError {
        case accessDenied
        case unavailable
        case placeNotFound(String)

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                "Artemis doesn't have access to your location. You can allow it in Settings › Privacy & Security › Location Services."
            case .unavailable:
                "Your location isn't available right now."
            case .placeNotFound(let place):
                "Couldn't find a place called \"\(place)\"."
            }
        }
    }

    /// A fix from the last few minutes is good enough for weather and nearby places.
    private var cached: CLLocation?

    func current() async throws -> CLLocation {
        if let cached, cached.timestamp.timeIntervalSinceNow > -300 { return cached }
        let location = try await RequestClassifier.withTimeout(.seconds(15)) {
            // The session asks for "while using" permission and keeps updates flowing.
            let session = CLServiceSession(authorization: .whenInUse)
            defer { session.invalidate() }
            for try await update in CLLocationUpdate.liveUpdates() {
                if let location = update.location { return location }
                if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
                    throw LocationError.accessDenied
                }
            }
            throw LocationError.unavailable
        }
        cached = location
        return location
    }

    /// "Paris, France" or a street address for a coordinate.
    @MainActor
    static func describe(_ location: CLLocation, detailed: Bool = false) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first else { return nil }
        if detailed, let address = item.address?.shortAddress ?? item.address?.fullAddress {
            return address
        }
        return item.addressRepresentations?.cityWithContext ?? item.address?.shortAddress
    }

    /// The first match for a place name, and how to call it.
    @MainActor
    static func resolve(_ place: String) async throws -> (location: CLLocation, name: String) {
        guard let request = MKGeocodingRequest(addressString: place),
              let item = try await request.mapItems.first else {
            throw LocationError.placeNotFound(place)
        }
        let name = item.addressRepresentations?.cityWithContext ?? item.name ?? place
        return (item.location, name)
    }

    /// A destination for directions. Names ("IKEA", "Central Station") and addresses are searched
    /// near the user first, so the nearest match wins; anything else is geocoded (another city).
    @MainActor
    static func mapItem(for place: String, near location: CLLocation) async throws -> MKMapItem {
        let search = MKLocalSearch.Request()
        search.naturalLanguageQuery = place
        search.resultTypes = [.address, .pointOfInterest]
        search.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        search.regionPriority = .required
        if let item = try? await MKLocalSearch(request: search).start().mapItems.first {
            return item
        }
        guard let request = MKGeocodingRequest(addressString: place),
              let item = try await request.mapItems.first else {
            throw LocationError.placeNotFound(place)
        }
        return item
    }
}

// MARK: - Weather

struct WeatherTool: Tool {
    let sink: ToolEventSink

    let name = "getWeather"
    let description = "Gets the current weather and the daily forecast for the user's location or a named place."

    @Generable
    struct Arguments {
        @Guide(description: "City or place, e.g. \"Paris\"; empty for the user's current location")
        var place: String
        @Guide(description: "Days of forecast to include, from 1 to 10")
        var days: Int
    }

    func call(arguments: Arguments) async throws -> String {
        let place = arguments.place.trimmingCharacters(in: .whitespacesAndNewlines)
        let location: CLLocation
        let placeName: String
        do {
            if place.isEmpty || ["here", "my location", "current location"].contains(place.lowercased()) {
                sink.send(.started(.location))
                location = try await LocationProvider.shared.current()
                placeName = await LocationProvider.describe(location) ?? "the user's location"
            } else {
                (location, placeName) = try await LocationProvider.resolve(place)
            }
        } catch {
            return error.localizedDescription
        }

        sink.send(.started(.weather))
        do {
            let forecast = try await OpenMeteo.forecast(for: location.coordinate, days: min(max(arguments.days, 1), 10))
            let current = forecast.current
            var lines = [
                "Weather in \(placeName) now: \(OpenMeteo.describe(current.weatherCode)), \(Self.temperature(current.temperature)) "
                    + "(feels like \(Self.temperature(current.apparentTemperature))), humidity \(current.humidity)%, "
                    + "wind \(Self.speed(current.windSpeed)).",
                "Forecast:",
            ]
            for (index, day) in forecast.daily.days.enumerated() {
                let date = day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
                let chance = forecast.daily.precipitationChance[safe: index].flatMap { $0 }.map { ", precipitation chance \($0)%" } ?? ""
                lines.append("- \(date): \(OpenMeteo.describe(forecast.daily.weatherCode[index])), "
                    + "\(Self.temperature(forecast.daily.low[index]))–\(Self.temperature(forecast.daily.high[index]))\(chance)")
            }
            return lines.joined(separator: "\n")
        } catch {
            return "The weather service failed: \(error.localizedDescription)"
        }
    }

    /// In the user's preferred unit (°C or °F).
    private static func temperature(_ celsius: Double) -> String {
        Measurement(value: celsius, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .narrow, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    private static func speed(_ kilometersPerHour: Double) -> String {
        Measurement(value: kilometersPerHour, unit: UnitSpeed.kilometersPerHour)
            .formatted(.measurement(width: .abbreviated, usage: .wind, numberFormatStyle: .number.precision(.fractionLength(0))))
    }
}

/// Forecasts from Open-Meteo (free, no API key; WeatherKit needs a paid developer account).
/// Only coordinates rounded to ~1 km leave the device.
enum OpenMeteo {
    static let attributionURL = URL(string: "https://open-meteo.com/")!

    struct Forecast: Decodable {
        struct Current: Decodable {
            let temperature: Double
            let apparentTemperature: Double
            let humidity: Int
            let weatherCode: Int
            let windSpeed: Double

            enum CodingKeys: String, CodingKey {
                case temperature = "temperature_2m"
                case apparentTemperature = "apparent_temperature"
                case humidity = "relative_humidity_2m"
                case weatherCode = "weather_code"
                case windSpeed = "wind_speed_10m"
            }
        }

        struct Daily: Decodable {
            let time: [String]
            let weatherCode: [Int]
            let high: [Double]
            let low: [Double]
            let precipitationChance: [Int?]

            enum CodingKeys: String, CodingKey {
                case time
                case weatherCode = "weather_code"
                case high = "temperature_2m_max"
                case low = "temperature_2m_min"
                case precipitationChance = "precipitation_probability_max"
            }

            /// Dates are local to the place, as YYYY-MM-DD.
            var days: [Date] {
                time.compactMap { PersonalDataTools.parseDate($0)?.date }
            }
        }

        let current: Current
        let daily: Daily
    }

    static func forecast(for coordinate: CLLocationCoordinate2D, days: Int) async throws -> Forecast {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: String(days)),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let forecast = try JSONDecoder().decode(Forecast.self, from: data)
        guard forecast.daily.days.count == forecast.daily.weatherCode.count,
              forecast.daily.high.count == forecast.daily.weatherCode.count,
              forecast.daily.low.count == forecast.daily.weatherCode.count else {
            throw URLError(.cannotParseResponse)
        }
        return forecast
    }

    /// WMO weather interpretation codes.
    static func describe(_ code: Int) -> String {
        switch code {
        case 0: "clear sky"
        case 1: "mainly clear"
        case 2: "partly cloudy"
        case 3: "overcast"
        case 45, 48: "fog"
        case 51, 53, 55: "drizzle"
        case 56, 57: "freezing drizzle"
        case 61: "light rain"
        case 63: "rain"
        case 65: "heavy rain"
        case 66, 67: "freezing rain"
        case 71: "light snow"
        case 73: "snow"
        case 75: "heavy snow"
        case 77: "snow grains"
        case 80, 81: "rain showers"
        case 82: "violent rain showers"
        case 85, 86: "snow showers"
        case 95: "thunderstorm"
        case 96, 99: "thunderstorm with hail"
        default: "unknown conditions"
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Places

struct CurrentLocationTool: Tool {
    let sink: ToolEventSink

    let name = "getCurrentLocation"
    let description = "Gets the address of the user's current location."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        sink.send(.started(.location))
        do {
            let location = try await LocationProvider.shared.current()
            guard let address = await LocationProvider.describe(location, detailed: true) else {
                return String(format: "Coordinates: %.5f, %.5f (no address found).", location.coordinate.latitude, location.coordinate.longitude)
            }
            let area = await LocationProvider.describe(location) ?? ""
            return "The user is at or near \(address)\(area.isEmpty ? "" : " (\(area))")."
        } catch {
            return error.localizedDescription
        }
    }
}

struct SearchPlacesTool: Tool {
    let sink: ToolEventSink

    let name = "searchPlaces"
    let description = "Finds places such as shops, restaurants or pharmacies near the user or in a named place."

    @Generable
    struct Arguments {
        @Guide(description: "What to look for, e.g. \"coffee\" or \"pharmacy\"")
        var query: String
        @Guide(description: "City or area to search in; empty to search near the user")
        var near: String
    }

    func call(arguments: Arguments) async throws -> String {
        let near = arguments.near.trimmingCharacters(in: .whitespacesAndNewlines)
        let center: CLLocation
        let userLocation: CLLocation?
        do {
            if near.isEmpty {
                sink.send(.started(.location))
                center = try await LocationProvider.shared.current()
                userLocation = center
            } else {
                center = try await LocationProvider.resolve(near).location
                userLocation = nil
            }
        } catch {
            return error.localizedDescription
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = arguments.query
        request.region = MKCoordinateRegion(center: center.coordinate, latitudinalMeters: 5000, longitudinalMeters: 5000)
        let items: [MKMapItem]
        do {
            items = try await MKLocalSearch(request: request).start().mapItems
        } catch {
            return "No places found for \"\(arguments.query)\"."
        }
        guard !items.isEmpty else { return "No places found for \"\(arguments.query)\"." }

        return items.prefix(8).map { item in
            var line = "- \(item.name ?? "Place")"
            if let address = item.address?.shortAddress { line += ", \(address)" }
            if let userLocation {
                let meters = Measurement(value: item.location.distance(from: userLocation), unit: UnitLength.meters)
                line += " — \(meters.formatted(.measurement(width: .abbreviated, usage: .road)))"
            }
            if let phone = item.phoneNumber { line += ", tel. \(phone)" }
            return line
        }.joined(separator: "\n")
    }
}

// MARK: - Travel

struct TravelTimeTool: Tool {
    let sink: ToolEventSink

    let name = "getTravelTime"
    let description = "Gets how long it takes to get somewhere, from the user's location or another start, and when to leave to arrive on time. "
        + "For the next event, plans the trip to the user's next calendar event that has a location."

    @Generable
    enum Transport {
        case driving
        case walking
        case transit
        case cycling
    }

    @Generable
    enum Destination {
        case place
        case nextEvent
    }

    @Generable
    struct Arguments {
        @Guide(description: "Where the trip starts, only if the user says: the name of one of the user's saved places or an address; empty for the user's current location")
        var from: String
        @Guide(description: "Where to go: a place (a saved place, an address or a place name), or nextEvent only when the user asks about their next event or meeting")
        var destination: Destination
        @Guide(description: "For a place: the name of one of the user's saved places, an address or a place name; empty otherwise")
        var place: String
        var transport: Transport
        @Guide(description: "Only if the user says when they have to arrive: that time as YYYY-MM-DDTHH:MM in local time; empty otherwise, to leave now or for the next event's start")
        var arriveBy: String
    }

    /// Margin suggested before leaving: finding keys, parking, the walk to the platform.
    private static let bufferMinutes = 5

    func call(arguments: Arguments) async throws -> String {
        let places = SavedPlaces.load()
        var start = arguments.from.trimmingCharacters(in: .whitespacesAndNewlines)
        var destination = arguments.place.trimmingCharacters(in: .whitespacesAndNewlines)
        var arrival = PersonalDataTools.parseDate(arguments.arriveBy)
            .flatMap { $0.hasTime ? Self.correctingDay(of: $0.date) : nil }
        var lines: [String] = []

        switch Self.destination(arguments.destination, place: destination) {
        case .nextEvent:
            sink.send(.started(.calendar))
            let event: PersonalDataStore.EventSummary
            do {
                guard let next = try await Self.nextEventWithLocation() else {
                    return "The user has no event with a location in the next two days. Ask where they want to go."
                }
                event = next
            } catch {
                return error.localizedDescription
            }
            destination = event.location ?? ""
            arrival = arrival ?? event.start
            lines.append("Next event: \"\(event.title)\" on \(PersonalDataTools.describe(event.start, withTime: true)) at \(destination).")
        case .place:
            guard !destination.isEmpty else { return "Ask the user where they want to go." }
            if let saved = SavedPlaces.place(named: destination, in: places) {
                lines.append("\(saved.name) is the user's saved place at \(saved.address).")
                destination = saved.address
            }
        }

        // "Home" is a saved place too, but the user's current location is the default start.
        var startName = "the user's location"
        if !start.isEmpty {
            startName = start
            if let saved = SavedPlaces.place(named: start, in: places) {
                lines.append("\(saved.name) is the user's saved place at \(saved.address).")
                start = saved.address
            }
        }

        let eta: Trip
        do {
            let origin: CLLocation
            if start.isEmpty {
                sink.send(.started(.location))
                origin = try await LocationProvider.shared.current()
            } else {
                origin = try await LocationProvider.resolve(start).location
            }
            eta = try await Self.trip(from: origin, to: destination, by: arguments.transport, arrival: arrival)
        } catch let error as LocationProvider.LocationError {
            return error.localizedDescription
        } catch {
            return "Couldn't get \(Self.mode(arguments.transport)) directions to \(destination): \(error.localizedDescription)"
        }

        let place = eta.placeName.isEmpty ? destination : eta.placeName
        let duration = Duration.seconds(eta.expectedTravelTime)
            .formatted(.units(allowed: [.hours, .minutes], width: .wide, fractionalPart: .hide(rounded: .up)))
        let distance = Measurement(value: eta.distance, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
        lines.append("\(Self.mode(arguments.transport).capitalized) from \(startName) to \(place): "
            + "about \(duration), \(distance).")

        if let arrival {
            let departure = eta.expectedDepartureDate
            if departure > Date() {
                let leaveBy = departure.addingTimeInterval(-Double(Self.bufferMinutes * 60))
                lines.append("To arrive by \(arrival.formatted(date: .omitted, time: .shortened)), leave at "
                    + "\(departure.formatted(date: .omitted, time: .shortened)); with a \(Self.bufferMinutes)-minute margin, "
                    + "by \(PersonalDataTools.describe(leaveBy, withTime: true)).")
            } else {
                let arrivesAt = Date().addingTimeInterval(eta.expectedTravelTime)
                lines.append("It's too late to arrive by \(arrival.formatted(date: .omitted, time: .shortened)): "
                    + "leaving now arrives around \(arrivesAt.formatted(date: .omitted, time: .shortened)).")
            }
        } else {
            lines.append("Leaving now arrives around \(eta.expectedArrivalDate.formatted(date: .omitted, time: .shortened)).")
        }
        lines.append("Tell the user how long the trip takes.")
        return lines.joined(separator: "\n")
    }

    /// The model picks nextEvent with a named place ("Gym", "airport"): the place wins.
    static func destination(_ destination: Destination, place: String) -> Destination {
        guard destination == .nextEvent, !place.isEmpty else { return destination }
        let words = ["event", "meeting", "appointment"]
        return words.contains { place.localizedCaseInsensitiveContains($0) } ? .nextEvent : .place
    }

    /// The model sometimes gets the date wrong ("by 18:00" on yesterday's date): a passed
    /// arrival whose time is still ahead today means today.
    static func correctingDay(of arrival: Date, now: Date = Date()) -> Date {
        let calendar = Calendar.current
        guard arrival < now,
              !calendar.isDate(arrival, inSameDayAs: now),
              let today = calendar.date(
                  bySettingHour: calendar.component(.hour, from: arrival),
                  minute: calendar.component(.minute, from: arrival),
                  second: 0,
                  of: now
              ),
              today > now else { return arrival }
        return today
    }

    /// What MapKit estimated, out of its main-actor types.
    private struct Trip: Sendable {
        var placeName: String
        var expectedTravelTime: TimeInterval
        var distance: CLLocationDistance
        var expectedDepartureDate: Date
        var expectedArrivalDate: Date
    }

    /// Leaves now, or arrives at `arrival` when it's still ahead (traffic is predicted for that time).
    @MainActor
    private static func trip(from origin: CLLocation, to destination: String, by transport: Transport, arrival: Date?) async throws -> Trip {
        let target = try await LocationProvider.mapItem(for: destination, near: origin)
        let request = MKDirections.Request()
        request.source = MKMapItem(location: origin, address: nil)
        request.destination = target
        request.transportType = transportType(transport)
        if let arrival, arrival > Date() {
            request.arrivalDate = arrival
        } else {
            request.departureDate = Date()
        }
        let eta = try await MKDirections(request: request).calculateETA()
        return Trip(
            placeName: [target.name, target.address?.shortAddress.flatMap { $0 == target.name ? nil : $0 }]
                .compactMap(\.self).joined(separator: ", "),
            expectedTravelTime: eta.expectedTravelTime,
            distance: eta.distance,
            expectedDepartureDate: eta.expectedDepartureDate,
            expectedArrivalDate: eta.expectedArrivalDate
        )
    }

    /// The first timed event in the next two days with a location, not yet started.
    private static func nextEventWithLocation() async throws -> PersonalDataStore.EventSummary? {
        let now = Date()
        return try await PersonalDataStore.shared.events(from: Calendar.current.startOfDay(for: now), days: 3)
            .first { !$0.isAllDay && $0.start > now && $0.start < now.addingTimeInterval(48 * 3600) && $0.location != nil }
    }

    private static func transportType(_ transport: Transport) -> MKDirectionsTransportType {
        switch transport {
        case .driving: .automobile
        case .walking: .walking
        case .transit: .transit
        case .cycling: .cycling
        }
    }

    private static func mode(_ transport: Transport) -> String {
        switch transport {
        case .driving: "driving"
        case .walking: "walking"
        case .transit: "public transport"
        case .cycling: "cycling"
        }
    }
}
