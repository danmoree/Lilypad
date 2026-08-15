//
//  SMCKit.swift
//  Lilypad
//
//  Low-level access to the Apple System Management Controller.
//
//  Shared verbatim between Lilypad.app (which only ever reads) and the
//  privileged helper (which is the only process allowed to write).
//
//  The struct layout below mirrors AppleSMC's SMCParamStruct. It was verified
//  against the C definition on Apple Silicon: total size 80 bytes, with field
//  offsets key=0, vers=4, pLimitData=12, keyInfo=28, result=40, status=41,
//  data8=42, data32=44, bytes=48. `SMCConnection.verifyLayout()` re-checks this
//  at runtime so a future toolchain change can't silently corrupt our writes.
//

import Foundation
import IOKit

// MARK: - Four-character key codes

/// SMC keys are four ASCII characters packed big-endian into a UInt32.
nonisolated func smcKeyCode(_ string: String) -> UInt32 {
    let scalars = Array(string.utf8)
    guard scalars.count == 4 else { return 0 }
    return (UInt32(scalars[0]) << 24) | (UInt32(scalars[1]) << 16)
        | (UInt32(scalars[2]) << 8) | UInt32(scalars[3])
}

nonisolated func smcKeyString(_ code: UInt32) -> String {
    let bytes = [
        UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
        UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
    ]
    return String(decoding: bytes, as: UTF8.self)
}

// MARK: - Raw structures

nonisolated struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

nonisolated struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

nonisolated struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    /// Explicit tail padding. In C this struct is 12 bytes — 9 rounded up to
    /// its 4-byte alignment — but Swift would leave it 9 bytes wide and pack
    /// the fields that follow it into the gap, shifting everything after
    /// `keyInfo` down by three bytes and shrinking SMCParamStruct to 76. That
    /// produces malformed transactions, so the padding is spelled out.
    private var reserved: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

/// 32-byte payload buffer carried by every SMC transaction.
typealias SMCBytes32 = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

nonisolated let smcZeroBytes: SMCBytes32 = (
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
)

nonisolated struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes32 = smcZeroBytes
}

/// Values for `SMCParamStruct.data8`, selecting the operation.
private enum SMCSelector: UInt8 {
    case readKey = 5
    case writeKey = 6
    case getKeyFromIndex = 8
    case getKeyInfo = 9
}

// MARK: - Errors

nonisolated enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern_return_t)
    case notConnected
    case keyNotFound(String)
    case ioFailed(String, kern_return_t)
    case notPrivileged(String)
    case sizeMismatch(String, expected: Int, got: Int)
    case layoutMismatch(Int)

    var description: String {
        switch self {
        case .serviceNotFound:
            return "AppleSMC service not found on this machine."
        case .openFailed(let code):
            return "Could not open AppleSMC (0x\(String(code, radix: 16)))."
        case .notConnected:
            return "Not connected to AppleSMC."
        case .keyNotFound(let key):
            return "SMC key \(key) is not present on this machine."
        case .ioFailed(let key, let code):
            return "SMC operation on \(key) failed (0x\(String(UInt32(bitPattern: code), radix: 16)))."
        case .notPrivileged(let key):
            return "Writing SMC key \(key) requires root privileges."
        case .sizeMismatch(let key, let expected, let got):
            return "SMC key \(key) expects \(expected) bytes, got \(got)."
        case .layoutMismatch(let size):
            return "SMCParamStruct layout is \(size) bytes, expected 80."
        }
    }
}

/// IOKit's `kIOReturnNotPrivileged`, returned when a non-root process writes.
private let kSMCReturnNotPrivileged = kern_return_t(bitPattern: 0xE000_02C1)

// MARK: - Connection

/// A serialized connection to the AppleSMC IOService.
///
/// Reading is available to any process. Writing requires root — an unprivileged
/// write comes back as `.notPrivileged` rather than silently doing nothing.
nonisolated final class SMCConnection: @unchecked Sendable {

    private let lock = NSLock()
    private var connection: io_connect_t = 0
    /// `keyInfo` never changes for a given key, so cache it. Without this every
    /// read costs two IOKit round trips, which adds up when polling ~20 sensors.
    private var infoCache: [UInt32: SMCKeyInfoData] = [:]

    init() {}

    deinit { try? close() }

    static func verifyLayout() throws {
        let size = MemoryLayout<SMCParamStruct>.stride
        guard size == 80 else { throw SMCError.layoutMismatch(size) }
    }

    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return connection != 0
    }

    func open() throws {
        try Self.verifyLayout()
        lock.lock(); defer { lock.unlock() }
        guard connection == 0 else { return }

        let service = IOServiceGetMatchingService(0, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard result == kIOReturnSuccess else { throw SMCError.openFailed(result) }
        connection = conn
    }

    func close() throws {
        lock.lock(); defer { lock.unlock() }
        guard connection != 0 else { return }
        IOServiceClose(connection)
        connection = 0
        infoCache.removeAll()
    }

    // MARK: Transport

    private func call(_ input: inout SMCParamStruct) throws -> SMCParamStruct {
        guard connection != 0 else { throw SMCError.notConnected }
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(
            connection, 2,
            &input, MemoryLayout<SMCParamStruct>.stride,
            &output, &outputSize
        )
        guard result == kIOReturnSuccess else {
            let key = smcKeyString(input.key)
            if result == kSMCReturnNotPrivileged { throw SMCError.notPrivileged(key) }
            throw SMCError.ioFailed(key, result)
        }
        return output
    }

    private func keyInfoLocked(_ key: UInt32) throws -> SMCKeyInfoData {
        if let cached = infoCache[key] { return cached }
        var input = SMCParamStruct()
        input.key = key
        input.data8 = SMCSelector.getKeyInfo.rawValue
        let output = try call(&input)
        infoCache[key] = output.keyInfo
        return output.keyInfo
    }

    // MARK: Reading

    /// Reads a key's raw payload plus its type metadata.
    func read(_ key: String) throws -> SMCValue {
        let code = smcKeyCode(key)
        lock.lock(); defer { lock.unlock() }
        let info = try keyInfoLocked(code)

        var input = SMCParamStruct()
        input.key = code
        input.keyInfo = info
        input.data8 = SMCSelector.readKey.rawValue
        let output = try call(&input)

        let size = Int(info.dataSize)
        var payload = [UInt8](repeating: 0, count: min(size, 32))
        withUnsafeBytes(of: output.bytes) { raw in
            for index in 0..<payload.count { payload[index] = raw[index] }
        }
        return SMCValue(key: key, type: smcKeyString(info.dataType),
                        attributes: info.dataAttributes, bytes: payload)
    }

    /// Reads a key and decodes it to a Double, or returns nil if absent/undecodable.
    func readNumber(_ key: String) -> Double? {
        guard let value = try? read(key) else { return nil }
        return value.doubleValue
    }

    /// Enumerates every key the SMC exposes. Used once at startup for discovery.
    func allKeys() throws -> [String] {
        guard let countValue = try? read("#KEY"), let count = countValue.doubleValue else {
            throw SMCError.keyNotFound("#KEY")
        }
        var keys: [String] = []
        keys.reserveCapacity(Int(count))
        lock.lock(); defer { lock.unlock() }
        for index in 0..<UInt32(count) {
            var input = SMCParamStruct()
            input.data8 = SMCSelector.getKeyFromIndex.rawValue
            input.data32 = index
            guard let output = try? call(&input) else { continue }
            keys.append(smcKeyString(output.key))
        }
        return keys
    }

    // MARK: Writing (root only)

    /// Writes raw bytes to a key. Fails with `.notPrivileged` unless running as root.
    func write(_ key: String, bytes: [UInt8]) throws {
        let code = smcKeyCode(key)
        lock.lock(); defer { lock.unlock() }
        let info = try keyInfoLocked(code)
        guard Int(info.dataSize) == bytes.count else {
            throw SMCError.sizeMismatch(key, expected: Int(info.dataSize), got: bytes.count)
        }

        var input = SMCParamStruct()
        input.key = code
        input.keyInfo = info
        input.data8 = SMCSelector.writeKey.rawValue
        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
        }
        _ = try call(&input)
    }

    func write(_ key: String, float value: Float) throws {
        try write(key, bytes: withUnsafeBytes(of: value) { Array($0) })
    }

    func write(_ key: String, uint8 value: UInt8) throws {
        try write(key, bytes: [value])
    }

    /// True when the key exists and its attribute bitmask has the write bit set.
    func isWritable(_ key: String) -> Bool {
        guard let value = try? read(key) else { return false }
        return value.attributes & 0x40 != 0
    }
}

// MARK: - Decoded value

nonisolated struct SMCValue: Sendable {
    let key: String
    let type: String
    let attributes: UInt8
    let bytes: [UInt8]

    var isWritable: Bool { attributes & 0x40 != 0 }

    /// Decodes the SMC's numeric encodings. Apple Silicon reports temperatures
    /// and fan speeds as little-endian IEEE floats (`flt `); the fixed-point
    /// types are retained for older Intel hardware.
    var doubleValue: Double? {
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: raw))
        case "ui8 ", "char":
            guard let first = bytes.first else { return nil }
            return Double(first)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
                | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case "si8 ":
            guard let first = bytes.first else { return nil }
            return Double(Int8(bitPattern: first))
        case "si16":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1])))
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256.0
        case "fp88":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 256.0
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4.0
        case "ioft":
            guard bytes.count >= 8 else { return nil }
            var raw: UInt64 = 0
            for index in 0..<8 { raw |= UInt64(bytes[index]) << (8 * UInt64(index)) }
            return Double(raw) / 65536.0
        default:
            return nil
        }
    }
}

// MARK: - Sensor roles

/// Which physical part of the machine a temperature sensor is measuring.
nonisolated enum SensorRole: String, Codable, Sendable {
    /// Enclosure surface — the aluminium your legs actually touch.
    case skin
    /// Battery pack, which fills most of the bottom case on a MacBook Pro and is
    /// the largest thermal mass directly under it.
    case battery
    /// Silicon die sensors (CPU/GPU/memory). Always far hotter than the case.
    case die
    case other
}

nonisolated struct SensorDefinition: Sendable {
    let key: String
    let label: String
    let role: SensorRole
}

/// Sensor keys grouped by what they measure.
///
/// Values here were read off an M5 Pro MacBook Pro (Mac17,8): the `Ts?P` skin
/// sensors and `TB?T` battery sensors sat around 30-33 °C while the `Tp??`
/// p-core die sensors sat at 47-51 °C, which is the expected case-vs-die split.
/// Discovery filters this list against the keys the running machine actually
/// exposes, so unknown models simply get a smaller set rather than bad data.
nonisolated enum SensorCatalog {

    /// The sensors that determine "how hot does this feel on a lap".
    /// Deliberately conservative: skin + battery only, both of which sit against
    /// the bottom case. Die sensors would read ~15 °C hotter and make the app
    /// run the fans long past the point the case felt fine.
    static let lapDefaults: [SensorDefinition] = [
        SensorDefinition(key: "Ts0P", label: "Case (front left)", role: .skin),
        SensorDefinition(key: "Ts1P", label: "Case (front right)", role: .skin),
        SensorDefinition(key: "TB0T", label: "Battery 1", role: .battery),
        SensorDefinition(key: "TB1T", label: "Battery 2", role: .battery),
        SensorDefinition(key: "TB2T", label: "Battery 3", role: .battery),
    ]

    /// Additional enclosure sensors, shown for information and available as
    /// opt-in inputs. Their exact placement is not documented by Apple, so they
    /// are not part of the default lap reading.
    static let enclosureExtras: [SensorDefinition] = [
        SensorDefinition(key: "TDBP", label: "Enclosure (bottom)", role: .skin),
        SensorDefinition(key: "TDTP", label: "Enclosure (top)", role: .skin),
        SensorDefinition(key: "TDEL", label: "Enclosure (edge left)", role: .skin),
        SensorDefinition(key: "TDER", label: "Enclosure (edge right)", role: .skin),
        SensorDefinition(key: "TDeL", label: "Enclosure (left)", role: .skin),
        SensorDefinition(key: "TDeR", label: "Enclosure (right)", role: .skin),
        SensorDefinition(key: "TDCR", label: "Enclosure (centre)", role: .skin),
        SensorDefinition(key: "TAOL", label: "Ambient", role: .other),
    ]

    /// Die sensors, used only for the thermal safety check.
    static let die: [SensorDefinition] = [
        SensorDefinition(key: "Tp00", label: "CPU p-core 0", role: .die),
        SensorDefinition(key: "Tp0C", label: "CPU p-core 1", role: .die),
        SensorDefinition(key: "Tp0K", label: "CPU p-core 2", role: .die),
        SensorDefinition(key: "Tp0R", label: "CPU p-core 3", role: .die),
        SensorDefinition(key: "Tg0C", label: "GPU 0", role: .die),
        SensorDefinition(key: "Tg0R", label: "GPU 1", role: .die),
        SensorDefinition(key: "Tm00", label: "Memory", role: .die),
        SensorDefinition(key: "TCMb", label: "Mainboard", role: .die),
    ]

    static var all: [SensorDefinition] { lapDefaults + enclosureExtras + die }

    /// A plausible on-die/on-case temperature. Filters out sensors that are
    /// disconnected (0.0) or reporting garbage.
    static func isPlausible(_ celsius: Double) -> Bool {
        celsius > 5 && celsius < 120
    }
}
