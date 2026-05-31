import Foundation
import CoreBluetooth

/// Constants for the Reticulum protocol over BLE.
enum ReticulumConfig {
    /// Reticulum BLE GATT service UUID (Standard RNode UART service).
    static let reticulumServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")

    /// Characteristic for writing to the Reticulum node.
    static let reticulumTxUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")

    /// Characteristic for receiving notifications from the Reticulum node.
    static let reticulumRxUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    /// Maximum Transmission Unit for Reticulum BLE packets.
    static let reticulumMTU = 512

    /// Interval between automatic announce broadcasts.
    static let reticulumAnnounceInterval: TimeInterval = 8.0

    /// Tag used in the derivation of the Reticulum destination hash.
    static let reticulumIdentityServiceTag = "safeguardian.mesh"

    /// CoreBluetooth state restoration IDs.
    static let reticulumRestorationCentral = "chat.safeguardian.reticulum.central"
    static let reticulumRestorationPeripheral = "chat.safeguardian.reticulum.peripheral"
}
