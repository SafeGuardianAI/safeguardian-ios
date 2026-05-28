import Foundation

/// Represents an autocomplete suggestion in the UI
struct AutocompleteSuggestion: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let range: NSRange
}
