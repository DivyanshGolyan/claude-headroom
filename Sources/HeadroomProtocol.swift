import Foundation

struct HeadroomFailure: Error, Codable {
    let code: String
    let message: String
    var retry_after_seconds: Double? = nil
}

struct HeadroomRequest: Codable {
    static let version = 1
    enum Operation: String, Codable { case status, refresh }
    let schema_version: Int
    let operation: Operation

    init(_ operation: Operation, version: Int = Self.version) {
        self.operation = operation
        self.schema_version = version
    }
}

struct HeadroomResponse: Codable {
    var schema_version = HeadroomRequest.version
    let data: HeadroomStatus?
    let error: HeadroomFailure?

    enum CodingKeys: String, CodingKey { case schema_version, data, error }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema_version, forKey: .schema_version)
        try container.encode(data, forKey: .data)
        try container.encode(error, forKey: .error)
    }
}

struct HeadroomStatus: Codable {
    struct Observation: Codable {
        enum Freshness: String, Codable { case fresh, aging, stale, unknown }
        let observed_at: Date
        let age_seconds: Double?
        let freshness: Freshness
        let quotas: [Quota]

        enum CodingKeys: String, CodingKey { case observed_at, age_seconds, freshness, quotas }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(observed_at, forKey: .observed_at)
            try container.encode(age_seconds, forKey: .age_seconds)
            try container.encode(freshness, forKey: .freshness)
            try container.encode(quotas, forKey: .quotas)
        }
    }

    struct Quota: Codable {
        let kind: String
        let used_percent: Double
        let resets_at: Date?
    }

    struct Prediction: Codable {
        enum Kind: String, Codable {
            case measuring, waiting_for_usage, unavailable, ready, on_track, spare
            case predicted_outage, likely_outage, outage
        }
        let kind: Kind
        var starts_at: Date? = nil
        var ends_at: Date? = nil
        var estimated_spare_percent: Int? = nil
        var reason: String? = nil
    }

    struct Update: Codable {
        let in_progress: Bool
        let last_error: HeadroomFailure?
        let retry_after_seconds: Double?

        enum CodingKeys: String, CodingKey { case in_progress, last_error, retry_after_seconds }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(in_progress, forKey: .in_progress)
            try container.encode(last_error, forKey: .last_error)
            try container.encode(retry_after_seconds, forKey: .retry_after_seconds)
        }
    }

    let observation: Observation?
    let forecast: Prediction
    let update: Update

    enum CodingKeys: String, CodingKey { case observation, forecast, update }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(observation, forKey: .observation)
        try container.encode(forecast, forKey: .forecast)
        try container.encode(update, forKey: .update)
    }
}

enum HeadroomJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
