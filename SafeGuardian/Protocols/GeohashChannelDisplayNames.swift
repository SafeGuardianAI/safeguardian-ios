import Foundation
import BitFoundation

extension GeohashChannelLevel {
    var displayName: String {
        switch self {
        case .building:
            return String(localized: "location_levels.building", comment: "Name for building-level location channel")
        case .block:
            return String(localized: "location_levels.block", comment: "Name for block-level location channel")
        case .neighborhood:
            return String(localized: "location_levels.neighborhood", comment: "Name for neighborhood-level location channel")
        case .city:
            return String(localized: "location_levels.city", comment: "Name for city-level location channel")
        case .province:
            return String(localized: "location_levels.province", comment: "Name for province-level location channel")
        case .region:
            return String(localized: "location_levels.region", comment: "Name for region-level location channel")
        }
    }
}

extension GeohashChannel {
    var displayName: String {
        "\(level.displayName) • \(geohash)"
    }
}

extension ChannelID {
    var displayName: String {
        switch self {
        case .mesh:
            return "Mesh"
        case .location(let ch):
            return ch.displayName
        }
    }
}
