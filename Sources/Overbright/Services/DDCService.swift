import CoreGraphics
import Darwin
import Foundation
import IOKit

/// Talks DDC/CI to external displays on Apple Silicon through IOAVService.
///
/// IOAVService is private IOKit API, so it is looked up with dlsym: on Intel
/// Macs or a future macOS without it, `isAvailable` is false and displays fall
/// back to software dimming instead of the app failing to launch.
///
/// Every call blocks on I2C for tens of milliseconds. Call from a background
/// queue, one display at a time.
final class DDCService: @unchecked Sendable {
    private typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias Read = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private typealias Write = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    /// One external display reachable over DDC, with the identity macOS reports
    /// for it so it can be matched to a `CGDirectDisplayID`.
    struct Endpoint: @unchecked Sendable {
        let service: CFTypeRef
        let vendor: UInt32
        let model: UInt32
        let serial: UInt32
        let name: String?
    }

    static let shared = DDCService()

    private let create: Create?
    private let read: Read?
    private let write: Write?

    var isAvailable: Bool { create != nil && read != nil && write != nil }

    private init() {
        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let handle, let address = dlsym(handle, name) else { return nil }
            return unsafeBitCast(address, to: type)
        }
        create = symbol("IOAVServiceCreateWithService", Create.self)
        read = symbol("IOAVServiceReadI2C", Read.self)
        write = symbol("IOAVServiceWriteI2C", Write.self)
    }

    /// Every external DDC endpoint. The registry lists each display's
    /// framebuffer (with its EDID identity in "DisplayAttributes") before that
    /// display's "DCPAVServiceProxy", so walking it in order pairs them up.
    func discover() -> [Endpoint] {
        guard let create else { return [] }
        var iterator = io_iterator_t()
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard IORegistryEntryCreateIterator(
            root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var endpoints: [Endpoint] = []
        var identity: [String: Any]?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if let attributes = property(entry, "DisplayAttributes") as? [String: Any] {
                identity = attributes["ProductAttributes"] as? [String: Any]
            }
            var nameBuffer = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &nameBuffer)
            guard String(cString: nameBuffer) == "DCPAVServiceProxy",
                  property(entry, "Location") as? String == "External",
                  let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else {
                continue
            }
            endpoints.append(Endpoint(
                service: service,
                vendor: (identity?["LegacyManufacturerID"] as? NSNumber)?.uint32Value ?? 0,
                model: (identity?["ProductID"] as? NSNumber)?.uint32Value ?? 0,
                serial: (identity?["SerialNumber"] as? NSNumber)?.uint32Value ?? 0,
                name: identity?["ProductName"] as? String
            ))
            identity = nil
        }
        return endpoints
    }

    /// Current and maximum value of a VCP feature, or nil if the display does
    /// not answer. Retries because displays often drop the first request.
    func readFeature(_ code: UInt8, on endpoint: Endpoint) -> (current: UInt16, maximum: UInt16)? {
        guard let read, let write else { return nil }
        for _ in 0..<4 {
            var request = DDC.getRequest(code: code)
            guard write(endpoint.service, DDC.i2cAddress, DDC.hostAddress, &request, UInt32(request.count)) == kIOReturnSuccess else {
                usleep(30_000)
                continue
            }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 12)
            if read(endpoint.service, DDC.i2cAddress, DDC.hostAddress, &reply, UInt32(reply.count)) == kIOReturnSuccess,
               let value = DDC.parseReply(reply, code: code) {
                return value
            }
            usleep(30_000)
        }
        return nil
    }

    /// Sets a VCP feature. Sent twice, as many displays ignore a single write.
    @discardableResult
    func writeFeature(_ code: UInt8, value: UInt16, on endpoint: Endpoint) -> Bool {
        guard let write else { return false }
        var succeeded = false
        for _ in 0..<2 {
            var request = DDC.setRequest(code: code, value: value)
            if write(endpoint.service, DDC.i2cAddress, DDC.hostAddress, &request, UInt32(request.count)) == kIOReturnSuccess {
                succeeded = true
            }
            usleep(10_000)
        }
        return succeeded
    }

    private func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
