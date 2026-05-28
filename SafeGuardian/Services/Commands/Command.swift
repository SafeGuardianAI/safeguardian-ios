import Foundation

/// The result of executing a command.
enum CommandResult {
    case success(message: String?)
    case error(message: String)
    case handled
}

/// The runtime context passed to every command at execution time.
/// Assembled ephemerally by CommandProcessor from its stored references.
@MainActor
struct CommandContext {
    let provider: (any CommandContextProvider)?
    let transport: (any Transport)?
    let identityManager: SecureIdentityStateManagerProtocol
}

/// A self-contained command object. Adding a command to SafeGuardian means
/// implementing this protocol in a new file and calling registry.register().
@MainActor
protocol Command {
    /// All trigger strings, e.g. ["/m", "/msg"].
    var names: [String] { get }
    /// Shown by the dispatcher on unrecognised input or parse error.
    var usage: String { get }
    func execute(args: String, context: CommandContext) -> CommandResult
}
