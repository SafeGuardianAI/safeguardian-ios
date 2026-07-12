import BitFoundation
import MapKit
import SafeGuardianMesh
import SwiftUI

/// Map surface over the geohash channel system. Plots every channel the device
/// currently resolves (region down to block) at its decoded center and opens the
/// existing LocationNotesView for that geohash on tap, so the location note feed
/// is reachable spatially rather than only from a list. Each pin and the header
/// legend surface presence from both transports: the BLE mesh (directly connected
/// peers) and the geohash/Nostr mesh (participants resolved for a channel).
///
/// Shared across iOS and macOS; the MapKit surface, UserAnnotation, and map
/// controls are all available on macOS 14+, so only the iOS-specific navigation
/// bar styling is platform-gated.
struct MapTabView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var channels = LocationChannelManager.shared
    @State private var camera: MapCameraPosition = .automatic
    @State private var sheet: GeohashSheet?

    private struct GeohashSheet: Identifiable {
        let geohash: String
        var id: String { geohash }
    }

    var body: some View {
        NavigationStack {
            mapContent
                .navigationTitle("Map")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .overlay(alignment: .top) { meshLegend }
                .overlay(alignment: .bottom) { permissionPrompt }
                .sheet(item: $sheet) { s in
                    LocationNotesView(geohash: s.geohash)
                        .environmentObject(viewModel)
                }
                .onAppear { channels.refreshChannels() }
        }
    }

    /// Channels with a non-empty, well-formed geohash. Filtering here keeps the
    /// Map content builder from emitting an annotation at the (0,0) fallback that
    /// an empty geohash decodes to.
    private var plottableChannels: [GeohashChannel] {
        channels.availableChannels.filter { !$0.geohash.isEmpty }
    }

    private var mapContent: some View {
        Map(position: $camera) {
            UserAnnotation()
            ForEach(plottableChannels) { ch in
                let center = Geohash.decodeCenter(ch.geohash)
                Annotation(
                    label(for: ch),
                    coordinate: CLLocationCoordinate2D(latitude: center.lat, longitude: center.lon)
                ) {
                    Button { sheet = GeohashSheet(geohash: ch.geohash) } label: { pin(for: ch) }
                        .buttonStyle(.plain)
                }
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
    }

    private func pin(for ch: GeohashChannel) -> some View {
        let here = viewModel.geohashParticipantCount(for: ch.geohash)
        return VStack(spacing: 1) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.blue)
            Text("#\(ch.geohash)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            if here > 0 {
                Text("\(here) here")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.green)
            }
        }
    }

    /// Presence summary for both transports, pinned to the top of the map.
    /// The antenna count is the BLE mesh (directly connected peers); the globe
    /// count is the geohash/Nostr mesh (participants visible in active channels).
    private var meshLegend: some View {
        let bleCount = viewModel.connectedPeers.count
        let geoCount = viewModel.geohashPeople.count
        return HStack(spacing: 14) {
            Label("\(bleCount)", systemImage: "antenna.radiowaves.left.and.right")
                .foregroundStyle(bleCount > 0 ? .blue : .secondary)
            Label("\(geoCount)", systemImage: "globe")
                .foregroundStyle(geoCount > 0 ? .green : .secondary)
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.top, 8)
    }

    private func label(for ch: GeohashChannel) -> String {
        channels.locationNames[ch.level] ?? levelName(ch.level)
    }

    private func levelName(_ level: GeohashChannelLevel) -> String {
        switch level {
        case .building: return "Building"
        case .block: return "Block"
        case .neighborhood: return "Neighborhood"
        case .city: return "City"
        case .province: return "Province"
        case .region: return "Region"
        }
    }

    @ViewBuilder private var permissionPrompt: some View {
        if plottableChannels.isEmpty {
            Button {
                channels.enableLocationChannels()
            } label: {
                Label("Enable location for geohash channels", systemImage: "location.fill")
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.blue, in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(.bottom, 24)
        }
    }
}
