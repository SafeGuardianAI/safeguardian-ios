import Foundation

@MainActor
struct BatteryCommand: Command {
    let names = ["/battery", "/bat"]
    let usage = "/battery"

    func execute(args: String, context: CommandContext) -> CommandResult {
        .success(message: "battery: \(DeviceMetrics.batteryPercent())%")
    }
}
