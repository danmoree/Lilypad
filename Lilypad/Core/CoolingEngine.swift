//
//  CoolingEngine.swift
//  Lilypad
//
//  The closed loop: read the case temperature, decide how hard to run the fans,
//  tell the helper, repeat until the case is comfortable again.
//
//  Two properties matter more than the control law itself:
//
//  * We only ever add cooling. The commanded speed is floored at whatever the
//    firmware was already asking for when we took over, so engaging Lilypad can
//    never make the machine run hotter than leaving it alone would have.
//  * Every command doubles as the helper's heartbeat. Stop sending and the fans
//    return to firmware control within eight seconds, no matter how we died.
//

import Foundation
import Observation

@Observable
final class CoolingEngine {

    nonisolated enum Outcome: Equatable, Sendable {
        case reachedTarget(seconds: Int)
        case timeLimit
        case stoppedByUser
        case failed(String)
    }

    nonisolated enum Phase: Equatable, Sendable {
        case idle
        case preparing
        /// Actively pushing air, still above target.
        case cooling
        /// At or below target, confirming it holds before declaring victory.
        case settling
        case finished(Outcome)

        var isActive: Bool {
            switch self {
            case .preparing, .cooling, .settling: return true
            case .idle, .finished: return false
            }
        }
    }

    // MARK: Tuning

    /// Deadband above the target before a reading counts as having climbed back
    /// above it. The skin sensors jitter by a tenth of a degree or two, and
    /// without this the settle timer would restart on noise alone.
    private static let settleHysteresis = 0.25
    /// Seconds the reading must stay at or below target before we call it done.
    private static let settleSeconds = 25.0
    /// Any silicon sensor above this and we go to full speed regardless of the
    /// user's noise preference — comfort never outranks the machine's safety.
    private static let dieOverrideCelsius = 95.0
    /// If the case hasn't dropped this much after `stallCheckSeconds`, the
    /// workload is generating heat faster than the fans can remove it.
    private static let stallDelta = 0.4
    private static let stallCheckSeconds = 240.0
    /// Quiet period after a session before auto-engage may fire again. Without
    /// it, a session that times out while the case is still above the trigger
    /// would restart the moment it went idle and run the fans indefinitely.
    private static let autoEngageCooldown = 180.0

    // MARK: State

    private(set) var phase: Phase = .idle
    private(set) var startedAt: Date?
    private(set) var deadline: Date?
    private(set) var startTemperature: Double?
    private(set) var commandedRPM: Double = 0
    private(set) var snapshot: FanSnapshot?
    /// True when the machine is producing heat faster than we can shed it.
    private(set) var isStalled = false
    private(set) var lastError: String?

    private let monitor: ThermalMonitor
    private let helper: HelperClient
    private let preferences: Preferences

    /// Seconds left in the session. Stored rather than computed: the view only
    /// redraws when an observed property changes, so a computed value would
    /// inherit the 2-second sensor cadence and appear to skip.
    private(set) var secondsRemaining: Int = 0
    /// Seconds left in the confirmation window once the target is reached.
    private(set) var settleSecondsRemaining: Int = 0

    private var loop: Task<Void, Never>?
    private var displayTimer: Timer?
    private var settlingSince: Date?
    private var lastSessionEnded: Date?
    /// Firmware's own fan targets, captured the moment before we took over.
    private var floorRPMs: [Double] = []

    init(monitor: ThermalMonitor, helper: HelperClient, preferences: Preferences) {
        self.monitor = monitor
        self.helper = helper
        self.preferences = preferences
    }

    // MARK: Derived

    /// True once the case has actually met the target — during the confirmation
    /// window and after a successful finish. Drives the "only full when done"
    /// state of the pad.
    var hasReachedTarget: Bool {
        switch phase {
        case .settling: return true
        case .finished(.reachedTarget): return true
        default: return false
        }
    }

    var elapsedSeconds: Int {
        guard let startedAt else { return 0 }
        return Int(Date().timeIntervalSince(startedAt))
    }

    /// How far along we are between the temperature at engage and the target.
    var progress: Double {
        guard let start = startTemperature,
              let current = monitor.lapTemperature else { return 0 }
        let span = start - preferences.targetCelsius
        guard span > 0.1 else { return 1 }
        return ((start - current) / span).clamped(to: 0...1)
    }

    // MARK: Control

    func engage() {
        guard !phase.isActive else { return }
        lastError = nil
        isStalled = false
        settlingSince = nil
        phase = .preparing

        loop = Task { [weak self] in await self?.run() }
    }

    /// Ticks once a second purely so the countdown reads like a countdown.
    private func startDisplayTimer() {
        displayTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            // Added to the main run loop below, so this always fires on the
            // main thread — no need to hop through a Task to reach the actor.
            MainActor.assumeIsolated { self?.updateCountdowns() }
        }
        // Tight tolerance: a loose one lets ticks drift together and skip a
        // displayed second, which is the exact symptom this replaces.
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
        updateCountdowns()
    }

    private func updateCountdowns() {
        // Rounded, not truncated: with truncation a tick landing a few
        // milliseconds late drops a whole displayed second.
        secondsRemaining = deadline.map { max(0, Int($0.timeIntervalSinceNow.rounded())) } ?? 0
        settleSecondsRemaining = settlingSince.map {
            max(0, Int((Self.settleSeconds - Date().timeIntervalSince($0)).rounded()))
        } ?? 0
    }

    func disengage(outcome: Outcome = .stoppedByUser) {
        loop?.cancel()
        loop = nil
        displayTimer?.invalidate()
        displayTimer = nil
        Task { [helper] in await helper.releaseControl() }
        settlingSince = nil
        deadline = nil
        commandedRPM = 0
        lastSessionEnded = Date()
        phase = .finished(outcome)

        // Drop back to idle after the result has had a moment on screen.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, case .finished = self.phase else { return }
            self.phase = .idle
            self.startedAt = nil
            self.startTemperature = nil
        }
    }

    private func run() async {
        // Capture what the firmware was already asking for. This becomes our
        // floor for the whole session.
        floorRPMs = monitor.firmwareFanTargets()
        startTemperature = monitor.lapTemperature
        startedAt = Date()

        let duration = preferences.maxMinutes * 60
        deadline = Date().addingTimeInterval(TimeInterval(duration))
        startDisplayTimer()

        do {
            try await helper.beginSession(maxDurationSeconds: duration)
        } catch {
            lastError = "\(error)"
            phase = .finished(.failed("\(error)"))
            return
        }

        phase = .cooling

        while !Task.isCancelled {
            monitor.refresh()

            if let deadline, Date() >= deadline {
                finish(.timeLimit)
                return
            }

            guard let lap = monitor.lapTemperature else {
                try? await Task.sleep(for: .seconds(2))
                continue
            }

            // Done? Require the target to hold, not just be touched once. The
            // fans keep running at the chosen speed throughout this window, so
            // it's a margin against a noisy reading rather than a coast.
            if lap <= preferences.targetCelsius {
                phase = .settling
                let since = settlingSince ?? Date()
                settlingSince = since
                if Date().timeIntervalSince(since) >= Self.settleSeconds {
                    finish(.reachedTarget(seconds: elapsedSeconds))
                    return
                }
            } else if lap > preferences.targetCelsius + Self.settleHysteresis {
                settlingSince = nil
                phase = .cooling
            }

            checkForStall(current: lap)

            do {
                let targets = computeTargets()
                commandedRPM = targets.max() ?? 0
                snapshot = try await helper.applyTargets(targets)
                lastError = nil
            } catch {
                lastError = "\(error)"
                // A single dropped call isn't fatal — the helper holds the last
                // command for eight seconds. Persistent failure will trip its
                // watchdog and release the fans, which is the safe outcome.
            }

            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// The fan speed to hold for the whole session.
    ///
    /// Deliberately open loop: speed depends on the user's chosen intensity and
    /// nothing else. It does *not* vary with how close the case is to target.
    ///
    /// Modulating on the error looks sensible and behaves badly. The fans
    /// respond in seconds but the case takes minutes, so easing off as the
    /// target approaches lets the case warm straight back up, which winds the
    /// fans up again — a slow oscillation that never settles and is audible as
    /// constant surging. Holding one speed until the target is actually reached
    /// gets there sooner and sounds like nothing at all.
    private func computeTargets() -> [Double] {
        let fans = monitor.fans
        guard !fans.isEmpty else { return [] }

        let dieIsHot = (monitor.dieTemperature ?? 0) > Self.dieOverrideCelsius

        return fans.enumerated().map { index, fan in
            // Never below what the firmware already wanted.
            let floor = max(fan.minRPM, floorRPMs.indices.contains(index)
                            ? floorRPMs[index] : fan.minRPM)
            if dieIsHot { return fan.maxRPM }
            return (floor + (fan.maxRPM - floor) * preferences.intensity)
                .clamped(to: fan.minRPM...fan.maxRPM)
        }
    }

    /// True when we're commanding essentially everything the fans have.
    var isAtFullSpeed: Bool {
        guard let ceiling = monitor.fans.map(\.maxRPM).max(), ceiling > 0 else { return false }
        return commandedRPM >= ceiling * 0.97
    }

    private func checkForStall(current: Double) {
        guard let start = startTemperature, let startedAt else { return }
        guard Date().timeIntervalSince(startedAt) >= Self.stallCheckSeconds else { return }
        isStalled = (start - current) < Self.stallDelta
    }

    private func finish(_ outcome: Outcome) {
        disengage(outcome: outcome)
    }

    // MARK: Auto-engage

    /// Called on each sample tick; starts a session on its own if the case has
    /// crossed the user's threshold.
    func considerAutoEngage() {
        guard preferences.autoEngage, !phase.isActive else { return }
        guard case .idle = phase else { return }
        if let last = lastSessionEnded,
           Date().timeIntervalSince(last) < Self.autoEngageCooldown { return }
        guard let lap = monitor.lapTemperature else { return }
        guard lap >= preferences.autoEngageCelsius else { return }
        engage()
    }
}
