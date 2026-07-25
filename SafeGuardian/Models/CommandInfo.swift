import SafeGuardianMesh
//
// CommandsInfo.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

// MARK: - CommandInfo Enum

enum CommandInfo: String, Identifiable {
    case agent
    case battery
    case bench
    case block
    case clear
    case gps
    case hug
    case message = "dm"
    case slap
    case unblock
    case who
    case favorite
    case unfavorite
    case shareloc
    case unshareloc
    case shares

    var id: String { rawValue }

    var alias: String { "/" + rawValue }

    var placeholder: String? {
        switch self {
        case .agent:
            return "<agent_id> <message>"
        case .bench, .block, .hug, .message, .slap, .unblock, .favorite, .unfavorite, .shareloc, .unshareloc:
            return "<" + String(localized: "content.input.nickname_placeholder") + ">"
        case .gps:
            return "[p]"
        case .battery, .clear, .who, .shares:
            return nil
        }
    }

    var description: String {
        switch self {
        case .agent:        String(localized: "content.commands.agent")
        case .battery:      String(localized: "content.commands.battery")
        case .bench:        String(localized: "content.commands.bench")
        case .block:        String(localized: "content.commands.block")
        case .clear:        String(localized: "content.commands.clear")
        case .gps:          String(localized: "content.commands.gps")
        case .hug:          String(localized: "content.commands.hug")
        case .message:      String(localized: "content.commands.message")
        case .slap:         String(localized: "content.commands.slap")
        case .unblock:      String(localized: "content.commands.unblock")
        case .who:          String(localized: "content.commands.who")
        case .favorite:     String(localized: "content.commands.favorite")
        case .unfavorite:   String(localized: "content.commands.unfavorite")
        case .shareloc:     String(localized: "content.commands.shareloc")
        case .unshareloc:   String(localized: "content.commands.unshareloc")
        case .shares:       String(localized: "content.commands.shares")
        }
    }

    static func all(isGeoPublic: Bool, isGeoDM: Bool) -> [CommandInfo] {
        let baseCommands: [CommandInfo] = [.agent, .battery, .block, .unblock, .clear, .gps, .hug, .message, .slap, .who, .shareloc, .unshareloc, .shares]
        if isGeoPublic || isGeoDM {
            return baseCommands + [.favorite, .unfavorite]
        }
        return baseCommands
    }
}
