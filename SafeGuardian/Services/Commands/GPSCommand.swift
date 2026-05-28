import Foundation

@MainActor
struct GPSCommand: Command {
    let names = ["/gps"]
    let usage = "/gps [p]"

    func execute(args: String, context: CommandContext) -> CommandResult {
        let locationManager = LocationStateManager.shared
        switch locationManager.permissionState {
        case .denied:
            context.provider?.addLocalMessage("location permission denied — opening Settings")
            SystemSettings.location.open()
            return .handled
        case .restricted:
            context.provider?.addLocalMessage("location permission restricted by device policy")
            return .handled
        case .notDetermined:
            context.provider?.addLocalMessage("requesting location permission — accept the system prompt, then run /gps again")
            locationManager.enableLocationChannels()
            return .handled
        case .authorized:
            break
        }

        let share = args.trimmed.lowercased() == "p"
        guard let loc = locationManager.currentLocation else {
            context.provider?.addLocalMessage("location not available yet — try again in a moment")
            return .handled
        }

        let lat = loc.coordinate.latitude
        let lon = loc.coordinate.longitude
        let accuracy = Int(loc.horizontalAccuracy.rounded())
        let formatted = String(format: "location: %.4f, %.4f (±%dm)", lat, lon, accuracy)

        if share {
            context.provider?.promptGPSShare()
        } else {
            context.provider?.addLocalMessage(formatted)
        }
        return .handled
    }
}
