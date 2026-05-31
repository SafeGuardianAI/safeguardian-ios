#if os(iOS)
import BitFoundation
import CoreBluetooth
import Foundation

// CoreBluetooth adapter for the Reticulum mesh. Advertises the standard RNode UART
// service so helix relay nodes and other Reticulum-capable peers can discover and
// connect to this device, and scans for the same service to discover peers.
//
// Reticulum handles its own segmentation; the BLE interface only needs to reassemble
// across GATT notifications using a 2-byte (big-endian) length prefix that precedes
// each reassembled packet.
final class ReticulumBLEInterface: NSObject {

    // MARK: - Callbacks

    var onPacket:          (Data, CBPeripheral) -> Void = { _, _ in }
    var onPeerConnected:   (PeerID, CBPeripheral) -> Void = { _, _ in }
    var onPeerDisconnected:(PeerID) -> Void = { _ in }

    // MARK: - State

    private var central:    CBCentralManager!
    private var peripheral: CBPeripheralManager!

    private struct PeripheralEntry {
        let peripheral: CBPeripheral
        var txChar: CBCharacteristic?
        var peerID: PeerID?
        var assemblyBuffer = Data()
        var expectedLength: Int = 0
    }
    private var peripherals: [String: PeripheralEntry] = [:]
    private var subscribedCentrals: [CBCentral] = []
    private var rxChar: CBMutableCharacteristic?

    // MARK: - Lifecycle

    func start() {
        let centralOpts: [String: Any] = [
            CBCentralManagerOptionRestoreIdentifierKey: ReticulumConfig.reticulumRestorationCentral
        ]
        central = CBCentralManager(delegate: self, queue: nil, options: centralOpts)

        let peripheralOpts: [String: Any] = [
            CBPeripheralManagerOptionRestoreIdentifierKey: ReticulumConfig.reticulumRestorationPeripheral
        ]
        peripheral = CBPeripheralManager(delegate: self, queue: nil, options: peripheralOpts)
    }

    func stop() {
        central?.stopScan()
        if peripheral?.isAdvertising == true { peripheral?.stopAdvertising() }
    }

    // MARK: - Send

    func send(_ packet: Data, to cbPeripheral: CBPeripheral) {
        guard let entry = peripherals[cbPeripheral.identifier.uuidString],
              let txChar = entry.txChar else { return }
        // Prefix with 2-byte big-endian length so the receiver can reassemble.
        var framed = Data()
        var len = UInt16(packet.count).bigEndian
        framed.append(Data(bytes: &len, count: 2))
        framed.append(packet)
        // Fragment to MTU if needed; Reticulum handles higher-level reassembly.
        let mtu = ReticulumConfig.reticulumMTU
        var offset = 0
        while offset < framed.count {
            let chunk = framed[offset..<min(offset + mtu, framed.count)]
            cbPeripheral.writeValue(Data(chunk), for: txChar, type: .withResponse)
            offset += mtu
        }
    }

    // Broadcast to all connected peripherals (for announce and public messages).
    func broadcast(_ packet: Data) {
        for (_, entry) in peripherals where entry.txChar != nil {
            send(packet, to: entry.peripheral)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension ReticulumBLEInterface: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(
                withServices: [ReticulumConfig.reticulumServiceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let uuid = peripheral.identifier.uuidString
        guard peripherals[uuid] == nil else { return }
        peripherals[uuid] = PeripheralEntry(peripheral: peripheral)
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([ReticulumConfig.reticulumServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        let uuid = peripheral.identifier.uuidString
        if let entry = peripherals[uuid], let peerID = entry.peerID {
            onPeerDisconnected(peerID)
        }
        peripherals.removeValue(forKey: uuid)
    }

    func centralManager(_ central: CBCentralManager,
                        willRestoreState dict: [String: Any]) {}
}

// MARK: - CBPeripheralDelegate

extension ReticulumBLEInterface: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: {
            $0.uuid == ReticulumConfig.reticulumServiceUUID
        }) else { return }
        peripheral.discoverCharacteristics(
            [ReticulumConfig.reticulumTxUUID, ReticulumConfig.reticulumRxUUID],
            for: service
        )
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let uuid = peripheral.identifier.uuidString
        for char in service.characteristics ?? [] {
            if char.uuid == ReticulumConfig.reticulumTxUUID {
                peripherals[uuid]?.txChar = char
            }
            if char.uuid == ReticulumConfig.reticulumRxUUID {
                peripheral.setNotifyValue(true, for: char)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == ReticulumConfig.reticulumRxUUID,
              let value = characteristic.value else { return }
        let uuid = peripheral.identifier.uuidString
        guard var entry = peripherals[uuid] else { return }
        entry.assemblyBuffer.append(value)

        // Consume complete length-prefixed frames from the buffer.
        while entry.assemblyBuffer.count >= 2 {
            let frameLen = Int(UInt16(bigEndian: entry.assemblyBuffer.withUnsafeBytes {
                $0.load(as: UInt16.self)
            }))
            guard entry.assemblyBuffer.count >= 2 + frameLen else { break }
            let packet = entry.assemblyBuffer[2..<(2 + frameLen)]
            entry.assemblyBuffer.removeFirst(2 + frameLen)
            peripherals[uuid] = entry
            onPacket(Data(packet), peripheral)
        }
        peripherals[uuid] = entry
    }
}

// MARK: - CBPeripheralManagerDelegate

extension ReticulumBLEInterface: CBPeripheralManagerDelegate {

    func peripheralManagerDidUpdateState(_ manager: CBPeripheralManager) {
        guard manager.state == .poweredOn else { return }
        let rx = CBMutableCharacteristic(
            type: ReticulumConfig.reticulumRxUUID,
            properties: [.notify],
            value: nil,
            permissions: .readable
        )
        let tx = CBMutableCharacteristic(
            type: ReticulumConfig.reticulumTxUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: .writeable
        )
        rxChar = rx
        let service = CBMutableService(type: ReticulumConfig.reticulumServiceUUID, primary: true)
        service.characteristics = [rx, tx]
        manager.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService,
                           error: Error?) {
        guard error == nil else { return }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [ReticulumConfig.reticulumServiceUUID],
            CBAdvertisementDataLocalNameKey: "rnode"
        ])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        if !subscribedCentrals.contains(where: { $0.identifier == central.identifier }) {
            subscribedCentrals.append(central)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribedCentrals.removeAll { $0.identifier == central.identifier }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard let value = request.value, value.count >= 2 else {
                peripheral.respond(to: request, withResult: .invalidAttributeValueLength)
                continue
            }
            // Deliver write data as an inbound packet. Attribute writes from centrals
            // arrive pre-framed (the central must use the same 2-byte length prefix).
            let frameLen = Int(UInt16(bigEndian: value.withUnsafeBytes { $0.load(as: UInt16.self) }))
            if value.count >= 2 + frameLen {
                let packet = value[2..<(2 + frameLen)]
                // No CBPeripheral handle for the writing central; use a sentinel.
                // ReticulumTransport treats these as inbound-only (announce processing).
                if let sentinel = peripherals.values.first?.peripheral {
                    onPacket(Data(packet), sentinel)
                }
            }
            peripheral.respond(to: request, withResult: .success)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           willRestoreState dict: [String: Any]) {}
}
#endif
