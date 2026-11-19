import Foundation
import CoreGraphics
import IOKit

/// DDC/CI over the Apple Silicon display coprocessor (IOAVService I²C), used to set the
/// hardware brightness of external monitors (VCP code 0x10).
final class DDCChannel {
    private let service: CFTypeRef
    private let queue = DispatchQueue(label: "ScreenControl.ddc", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: [UInt8: UInt16] = [:]
    private var writing = false

    init(service: CFTypeRef) { self.service = service }

    // MARK: Reading

    /// Reads a VCP value synchronously (call off the main thread). Returns nil when the monitor
    /// does not answer after a few attempts.
    func read(_ code: UInt8) -> (current: UInt16, maximum: UInt16)? {
        queue.sync { readUnlocked(code) }
    }

    private func readUnlocked(_ code: UInt8) -> (current: UInt16, maximum: UInt16)? {
        guard let write = DDC.writeI2C, let read = DDC.readI2C else { return nil }
        var request: [UInt8] = [0x82, 0x01, code, 0]
        request[3] = DDC.checksum(request[0..<3])
        for _ in 0..<4 {
            let sent = request.withUnsafeMutableBytes { write(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
            usleep(40_000)
            var reply = [UInt8](repeating: 0, count: 12)
            let received = reply.withUnsafeMutableBytes { read(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
            if sent == 0, received == 0, reply[2] == 0x02, reply[3] == 0x00, reply[4] == code {
                let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
                let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
                if maximum > 0 { return (current, maximum) }
            }
            usleep(30_000)
        }
        return nil
    }

    // MARK: Writing

    /// Queues a VCP write. Writes are coalesced: while a slider is dragged only the latest value
    /// is sent, and the final value is always sent.
    func write(_ code: UInt8, value: UInt16) {
        lock.lock()
        pending[code] = value
        let start = !writing
        writing = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    /// Writes at once and waits for it (before a display is switched off).
    func writeNow(_ code: UInt8, value: UInt16) {
        queue.sync { send(code, value) }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let (code, value) = pending.first else {
                writing = false
                lock.unlock()
                return
            }
            pending[code] = nil
            lock.unlock()
            send(code, value)
            usleep(25_000)
        }
    }

    private func send(_ code: UInt8, _ value: UInt16) {
        guard let write = DDC.writeI2C else { return }
        var packet: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = DDC.checksum(packet[0..<5])
        // Some monitors drop single writes: send twice, as MonitorControl does.
        for attempt in 0..<2 {
            _ = packet.withUnsafeMutableBytes { write(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
            if attempt == 0 { usleep(10_000) }
        }
    }
}

enum DDC {
    typealias CreateService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias I2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    static let createService = PrivateAPI.symbol(nil, "IOAVServiceCreateWithService", as: CreateService.self)
    static let writeI2C = PrivateAPI.symbol(nil, "IOAVServiceWriteI2C", as: I2C.self)
    static let readI2C = PrivateAPI.symbol(nil, "IOAVServiceReadI2C", as: I2C.self)

    static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        bytes.reduce(UInt8(0x6E ^ 0x51)) { $0 ^ $1 }
    }

    struct Endpoint {
        var vendor: UInt32?
        var model: UInt32?
        var serial: UInt32?
        var channel: DDCChannel
    }

    /// Walks the IORegistry: each external `DCPAVServiceProxy` follows the `AppleCLCD2`
    /// framebuffer it belongs to, whose attributes identify the monitor.
    static func discover() -> [Endpoint] {
        guard let createService else { return [] }
        var iterator = io_iterator_t()
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var endpoints: [Endpoint] = []
        var lastIdentity: (UInt32?, UInt32?, UInt32?)?
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            var nameBuffer = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &nameBuffer)
            let name = String(cString: nameBuffer)

            if name == "AppleCLCD2" || name == "IOMobileFramebufferShim" {
                let attributes = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any]
                if let product = attributes?["ProductAttributes"] as? [String: Any] {
                    lastIdentity = (
                        (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
                        (product["ProductID"] as? NSNumber)?.uint32Value,
                        (product["SerialNumber"] as? NSNumber)?.uint32Value
                    )
                } else {
                    lastIdentity = nil
                }
            } else if name == "DCPAVServiceProxy" {
                let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
                guard location == "External", let service = createService(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
                endpoints.append(Endpoint(vendor: lastIdentity?.0, model: lastIdentity?.1, serial: lastIdentity?.2,
                                          channel: DDCChannel(service: service)))
                lastIdentity = nil
            }
        }
        return endpoints
    }

    /// Pairs CoreGraphics displays with DDC endpoints by vendor, model and serial number.
    static func match(_ displays: [(id: CGDirectDisplayID, vendor: UInt32, model: UInt32, serial: UInt32)],
                      _ endpoints: [Endpoint]) -> [CGDirectDisplayID: DDCChannel] {
        var remaining = endpoints
        var result: [CGDirectDisplayID: DDCChannel] = [:]
        for display in displays {
            let sameModel = remaining.indices.filter { remaining[$0].vendor == display.vendor && remaining[$0].model == display.model }
            let index = sameModel.first { remaining[$0].serial == display.serial } ?? sameModel.first
                ?? (displays.count == 1 && remaining.count == 1 ? 0 : nil)
            if let index {
                result[display.id] = remaining[index].channel
                remaining.remove(at: index)
            }
        }
        return result
    }
}
