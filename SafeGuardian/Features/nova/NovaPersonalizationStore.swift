// NovaPersonalizationStore.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import Foundation

/// Stores the user-editable personalization blurb for Nova.
/// The blurb is appended to the base system prompt as a "User preference:" line.
/// It is capped at maxLength characters to limit its impact on small-model context windows.
@Observable @MainActor
final class NovaPersonalizationStore {
    static let shared = NovaPersonalizationStore()
    static let maxLength = 150
    private static let defaultsKey = "nova.personalizationBlurb"

    private(set) var blurb: String {
        didSet { UserDefaults.standard.set(blurb, forKey: Self.defaultsKey) }
    }

    private init() {
        blurb = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? ""
    }

    func set(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        blurb = trimmed.count > Self.maxLength
            ? String(trimmed.prefix(Self.maxLength))
            : trimmed
    }
}
