import Foundation

public enum GeohashChannelLevel: CaseIterable, Codable, Equatable, Sendable {
    case building
    case block
    case neighborhood
    case city
    case province
    case region

    public var precision: Int {
        switch self {
        case .building: return 8
        case .block: return 7
        case .neighborhood: return 6
        case .city: return 5
        case .province: return 4
        case .region: return 2
        }
    }
}

extension GeohashChannelLevel {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let raw = try? container.decode(String.self) {
            switch raw {
            case "building": self = .building
            case "block": self = .block
            case "neighborhood": self = .neighborhood
            case "city": self = .city
            case "region": self = .province
            case "country": self = .region
            case "province": self = .province
            default: self = .block
            }
        } else if let precision = try? container.decode(Int.self) {
            switch precision {
            case 8: self = .building
            case 7: self = .block
            case 6: self = .neighborhood
            case 5: self = .city
            case 4: self = .province
            case 0...3: self = .region
            default: self = .block
            }
        } else {
            self = .block
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .building: try container.encode("building")
        case .block: try container.encode("block")
        case .neighborhood: try container.encode("neighborhood")
        case .city: try container.encode("city")
        case .province: try container.encode("province")
        case .region: try container.encode("region")
        }
    }
}

public struct GeohashChannel: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let level: GeohashChannelLevel
    public let geohash: String

    public init(level: GeohashChannelLevel, geohash: String) {
        self.level = level
        self.geohash = geohash
    }

    public var id: String { "\(level)-\(geohash)" }
}

public enum ChannelID: Equatable, Codable, Sendable {
    case mesh
    case location(GeohashChannel)

    public var nostrGeohashTag: String? {
        switch self {
        case .mesh: return nil
        case .location(let ch): return ch.geohash
        }
    }

    public var isMesh: Bool {
        switch self {
        case .mesh: return true
        case .location: return false
        }
    }

    public var isLocation: Bool {
        switch self {
        case .mesh: return false
        case .location: return true
        }
    }
}

extension ChannelID {
    public var contextKey: String {
        switch self {
        case .mesh: return "mesh"
        case .location(let ch): return "geo:\(ch.geohash)"
        }
    }
}
