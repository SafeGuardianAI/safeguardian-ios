#if DEBUG
#if os(macOS)
import AppKit
#endif
import Foundation

@MainActor
struct LogCommand: Command {
    let names = ["/log"]
    let usage = "/log [open|clear|format <jsonl|sharegpt>]"

    func execute(args: String, context: CommandContext) -> CommandResult {
        let logger = ConversationLogger.shared
        let arg = args.trimmingCharacters(in: .whitespaces).lowercased()

        switch arg {
        case "":
            context.provider?.addLocalMessage(
                "conversations: \(logger.entryCount) entries · \(logger.fileSizeString) · format: \(logger.format.rawValue)\npath: \(logger.logFilePath)"
            )
        case "open":
            #if os(macOS)
            NSWorkspace.shared.open(URL(fileURLWithPath: logger.logDirPath))
            context.provider?.addLocalMessage("opened \(logger.logDirPath)")
            #else
            context.provider?.addLocalMessage("path: \(logger.logFilePath)")
            #endif
        case "clear":
            logger.clear()
            context.provider?.addLocalMessage("conversation log cleared")
        default:
            if arg.hasPrefix("format ") {
                let fmt = String(arg.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                guard let f = LogFormat(rawValue: fmt) else {
                    return .error(message: "unknown format '\(fmt)' — use jsonl or sharegpt")
                }
                logger.format = f
                context.provider?.addLocalMessage("log format set to \(f.rawValue)")
            } else {
                return .error(message: usage)
            }
        }
        return .handled
    }
}
#endif
