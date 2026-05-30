// RequestLocation.swift
// SafeGuardian
//
// This is free and unencumbered software released into the public domain.

import BitFoundation
import Foundation
import MLXLMCommon

extension AgentToolEntry {
    /// Sends a structured location request to a specific peer and suspends until
    /// the peer approves or declines. No inference runs on the receiving side —
    /// the peer sees a consent prompt and their response is returned verbatim.
    /// Returns "denied" if the peer declines, "unavailable" if GPS is off,
    /// or a "lat,lon accuracy:Xm" string on approval.
    static func requestPeerLocation() -> AgentToolEntry {
        make(
            name: "request_peer_location",
            description: "Request the current GPS location from a specific peer. The peer will see a consent prompt. Returns their location as 'lat,lon accuracy:Xm', or 'denied' / 'unavailable' if they decline or have GPS off.",
            parameters: [
                .required("peer_id", type: .string, description: "The PeerID of the peer to request location from — use list_peers first.")
            ]
        ) { args, proxy in
            guard case .string(let peerIDStr) = args["peer_id"] else {
                return #"{"error":"peer_id is required"}"#
            }
            let peerID = PeerID(str: peerIDStr)
            return await proxy.requestFromPeer(type: "location", peerID: peerID)
        }
    }
}
