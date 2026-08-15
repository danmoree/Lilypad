//
//  FanControl.swift
//  Lilypad
//
//  Discovery and control of the fans exposed by the SMC.
//
//  Reading is safe from any process. `setForcedTarget` / `releaseToFirmware`
//  only succeed as root and are therefore only ever called from the helper.
//

import Foundation

/// One fan's live state.
nonisolated struct FanState: Codable, Sendable, Identifiable {
    var index: Int
    /// Measured speed right now.
    var actualRPM: Double
    /// Firmware's floor. We never command below this.
    var minRPM: Double
    /// Firmware's ceiling. We never command above this.
    var maxRPM: Double
    /// Commanded speed. While unforced this mirrors the firmware's own intent.
    var targetRPM: Double
    /// True when this fan is under our control rather than the firmware's.
    var forced: Bool

    var id: Int { index }

    /// Position between idle and full tilt, 0...1.
    var loadFraction: Double {
        guard maxRPM > minRPM else { return 0 }
        return ((actualRPM - minRPM) / (maxRPM - minRPM)).clamped(to: 0...1)
    }
}

/// Everything the helper reports back in one round trip.
nonisolated struct FanSnapshot: Codable, Sendable {
    var fans: [FanState] = []
    var sessionActive: Bool = false
    var secondsRemaining: Int = 0
    var helperVersion: String = ""

    var maxActualRPM: Double { fans.map(\.actualRPM).max() ?? 0 }
    var anyForced: Bool { fans.contains(where: \.forced) }
}

/// Reads and (as root) writes the SMC's fan keys.
///
/// Key names were confirmed by enumerating all 3501 SMC keys on an M5 Pro
/// MacBook Pro. On this generation the mode key is lowercase `F0md` — Intel
/// Macs used `F0Md` — so both spellings are probed. `F0Tg` (target) and the
/// mode key are the only two with the write bit (0x40) set; everything else is
/// read-only, which is why those are the only keys we ever write.
nonisolated final class FanController: @unchecked Sendable {

    private let smc: SMCConnection
    private let lock = NSLock()
    /// Resolved once: the mode key spelling this machine uses, per fan.
    private var modeKeys: [Int: String] = [:]
    private var fanCountCache: Int?

    init(smc: SMCConnection) {
        self.smc = smc
    }

    // MARK: Key names

    private func actualKey(_ index: Int) -> String { "F\(index)Ac" }
    private func minKey(_ index: Int) -> String { "F\(index)Mn" }
    private func maxKey(_ index: Int) -> String { "F\(index)Mx" }
    private func targetKey(_ index: Int) -> String { "F\(index)Tg" }

    /// Apple Silicon uses `F0md`; Intel used `F0Md`. Resolve whichever exists.
    private func modeKey(_ index: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached = modeKeys[index] { return cached }
        for candidate in ["F\(index)md", "F\(index)Md"] {
            if let value = try? smc.read(candidate), value.isWritable {
                modeKeys[index] = candidate
                return candidate
            }
        }
        return nil
    }

    // MARK: Reading

    var fanCount: Int {
        if let cached = fanCountCache { return cached }
        let count = Int(smc.readNumber("FNum") ?? 0)
        let clamped = max(0, min(count, 8))
        fanCountCache = clamped
        return clamped
    }

    func state(of index: Int) -> FanState? {
        guard let actual = smc.readNumber(actualKey(index)),
              let minimum = smc.readNumber(minKey(index)),
              let maximum = smc.readNumber(maxKey(index)),
              maximum > minimum
        else { return nil }

        let target = smc.readNumber(targetKey(index)) ?? actual
        var forced = false
        if let key = modeKey(index), let mode = smc.readNumber(key) {
            forced = mode >= 1
        }
        return FanState(index: index, actualRPM: actual, minRPM: minimum,
                        maxRPM: maximum, targetRPM: target, forced: forced)
    }

    func allStates() -> [FanState] {
        (0..<fanCount).compactMap { state(of: $0) }
    }

    /// True when this machine exposes writable fan keys at all. Fanless Macs
    /// (MacBook Air) report `FNum` = 0 and are unsupported by design.
    func supportsControl() -> Bool {
        guard fanCount > 0 else { return false }
        guard modeKey(0) != nil else { return false }
        return smc.isWritable(targetKey(0))
    }

    // MARK: Writing — root only

    /// Takes control of a fan and commands a speed.
    ///
    /// The requested RPM is clamped into the firmware's own `[min, max]` range,
    /// so this can never drive a fan outside limits Apple already permits, and
    /// never below the idle floor.
    @discardableResult
    func setForcedTarget(_ index: Int, rpm: Double) throws -> Double {
        guard let mode = modeKey(index) else {
            throw SMCError.keyNotFound("F\(index)md")
        }
        guard let minimum = smc.readNumber(minKey(index)),
              let maximum = smc.readNumber(maxKey(index)),
              maximum > minimum
        else {
            throw SMCError.keyNotFound(minKey(index))
        }

        let clamped = rpm.clamped(to: minimum...maximum)
        // Order matters: assert forced mode first, then the target. Writing the
        // target while the firmware still owns the fan would just be overwritten.
        try smc.write(mode, uint8: 1)
        try smc.write(targetKey(index), float: Float(clamped))
        return clamped
    }

    /// Hands a fan back to the firmware's own thermal management.
    func releaseToFirmware(_ index: Int) throws {
        guard let mode = modeKey(index) else { return }
        try smc.write(mode, uint8: 0)
    }

    /// Hands every fan back. Best effort: one failing fan must not prevent the
    /// others being released, so errors are collected rather than thrown early.
    @discardableResult
    func releaseAll() -> [Error] {
        var errors: [Error] = []
        for index in 0..<fanCount {
            do { try releaseToFirmware(index) } catch { errors.append(error) }
        }
        return errors
    }
}

// MARK: - Helpers

extension Comparable {
    /// Explicitly nonisolated: the app target compiles with MainActor default
    /// isolation, which would otherwise make this helper unusable from the SMC
    /// and helper code that runs off the main actor.
    nonisolated func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
