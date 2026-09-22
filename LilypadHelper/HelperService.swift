//
//  HelperService.swift
//  LilypadHelper
//
//  The root-privileged half of Lilypad. Runs as a LaunchDaemon and is the only
//  process that writes to the SMC.
//
//  Safety model — the helper assumes the app will misbehave:
//
//   * Every requested RPM is clamped into the firmware's own [min, max] range,
//     so the fans can never be driven outside limits Apple already permits, and
//     never below the idle floor.
//   * A session only stays alive while the app keeps heartbeating. Eight
//     seconds of silence (crash, hang, force-quit, SIGKILL of the app) and the
//     fans go back to firmware control on their own.
//   * Sessions have a hard ceiling of one hour regardless of what the app asks.
//   * On its own launch the helper releases any fan it finds still forced,
//     which recovers the machine if the helper itself was killed mid-session.
//

import Foundation
import os.log
import Security
import ServiceManagement

private let log = OSLog(subsystem: "com.lilypad.helper", category: "helper")

nonisolated final class HelperService: NSObject, NSXPCListenerDelegate,
                                       LilypadHelperProtocol, @unchecked Sendable {

    private let smc = SMCConnection()
    private let fans: FanController

    private let lock = NSLock()
    private var sessionActive = false
    private var sessionDeadline: Date?
    private var lastHeartbeat = Date.distantPast
    private weak var owningConnection: NSXPCConnection?

    private let watchdogQueue = DispatchQueue(label: "com.lilypad.helper.watchdog")
    private var watchdog: DispatchSourceTimer?

    override init() {
        fans = FanController(smc: smc)
        super.init()
    }

    // MARK: - Lifecycle

    func start() throws {
        try smc.open()
        os_log("helper %{public}@ starting, %d fan(s)", log: log, type: .info,
               HelperInfo.version, fans.fanCount)

        // If we were killed mid-session the fans may still be forced. Nothing
        // is heartbeating them now, so hand them straight back.
        recoverOrphanedFans()
        startWatchdog()
    }

    private func recoverOrphanedFans() {
        let stuck = fans.allStates().filter(\.forced)
        guard !stuck.isEmpty else { return }
        os_log("found %d fan(s) still forced at launch, releasing", log: log,
               type: .default, stuck.count)
        for error in fans.releaseAll() {
            os_log("release failed: %{public}@", log: log, type: .error, "\(error)")
        }
    }

    /// Fires once a second and is the backstop for every failure mode that
    /// isn't a clean `releaseControl` call.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.checkWatchdog() }
        watchdog = timer
        timer.resume()
    }

    private func checkWatchdog() {
        lock.lock()
        guard sessionActive else { lock.unlock(); return }

        let now = Date()
        var reason: String?
        if now.timeIntervalSince(lastHeartbeat) > HelperInfo.heartbeatTimeoutSeconds {
            reason = "client stopped responding"
        } else if let deadline = sessionDeadline, now >= deadline {
            reason = "session reached its time limit"
        }
        guard let reason else { lock.unlock(); return }

        sessionActive = false
        sessionDeadline = nil
        owningConnection = nil
        lock.unlock()

        os_log("watchdog releasing fans: %{public}@", log: log, type: .default, reason)
        for error in fans.releaseAll() {
            os_log("watchdog release failed: %{public}@", log: log, type: .error, "\(error)")
        }
    }

    /// Called from the signal handlers on the way out.
    func emergencyRelease() {
        lock.lock()
        sessionActive = false
        sessionDeadline = nil
        lock.unlock()
        _ = fans.releaseAll()
    }

    // MARK: - Client validation

    private static let clientRequirement = """
    identifier "\(HelperInfo.clientBundleIdentifier)" \
    and anchor apple generic \
    and certificate leaf[subject.OU] = "\(HelperInfo.clientTeamIdentifier)"
    """

    /// Requires the connecting process to be signed by the expected team and to
    /// carry the app's bundle identifier, and to be running as a normal user.
    ///
    /// This up-front check is by PID, which is in principle open to PID-reuse
    /// races, so the same requirement is also installed on the connection with
    /// `setCodeSigningRequirement`, which XPC enforces against the audit token.
    private func isClientTrusted(_ connection: NSXPCConnection) -> Bool {
        let uid = connection.effectiveUserIdentifier
        guard uid != 0 else {
            os_log("rejecting connection from root", log: log, type: .error)
            return false
        }

        let pid = connection.processIdentifier
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code
        else {
            os_log("could not obtain code object for pid %d", log: log, type: .error, pid)
            return false
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(Self.clientRequirement as CFString, [], &requirement)
                == errSecSuccess, let requirement
        else { return false }

        let status = SecCodeCheckValidity(code, [], requirement)
        if status != errSecSuccess {
            os_log("client pid %d failed signature check (%d)", log: log, type: .error,
                   pid, Int(status))
            return false
        }
        return true
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard isClientTrusted(connection) else { return false }
        // The PID check above is racy; this one is enforced by XPC against the
        // connection's audit token on every message, which closes that gap.
        connection.setCodeSigningRequirement(Self.clientRequirement)

        connection.exportedInterface = NSXPCInterface(with: LilypadHelperProtocol.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self, weak connection] in
            self?.connectionDropped(connection)
        }
        connection.interruptionHandler = { [weak self, weak connection] in
            self?.connectionDropped(connection)
        }
        connection.resume()
        os_log("accepted client pid %d", log: log, type: .info, connection.processIdentifier)
        return true
    }

    /// If the connection that owned the session goes away, release immediately
    /// rather than waiting out the heartbeat timeout.
    private func connectionDropped(_ connection: NSXPCConnection?) {
        lock.lock()
        let owned = sessionActive && (owningConnection == nil || owningConnection === connection)
        if owned {
            sessionActive = false
            sessionDeadline = nil
            owningConnection = nil
        }
        lock.unlock()

        guard owned else { return }
        os_log("owning client disconnected, releasing fans", log: log, type: .default)
        _ = fans.releaseAll()
    }

    // MARK: - LilypadHelperProtocol

    func handshake(reply: @escaping (String) -> Void) {
        reply(HelperInfo.version)
    }

    private func makeSnapshot() -> FanSnapshot {
        lock.lock()
        let active = sessionActive
        let remaining = sessionDeadline.map { Int(max(0, $0.timeIntervalSinceNow)) } ?? 0
        lock.unlock()
        return FanSnapshot(fans: fans.allStates(), sessionActive: active,
                           secondsRemaining: remaining, helperVersion: HelperInfo.version)
    }

    func readSnapshot(reply: @escaping (Data?, String?) -> Void) {
        do {
            reply(try JSONEncoder().encode(makeSnapshot()), nil)
        } catch {
            reply(nil, "\(error)")
        }
    }

    func beginSession(maxDurationSeconds: Int, reply: @escaping (String?) -> Void) {
        guard fans.supportsControl() else {
            reply("This Mac does not expose writable fan controls.")
            return
        }
        let duration = max(10, min(maxDurationSeconds, HelperInfo.absoluteMaxSessionSeconds))
        lock.lock()
        sessionActive = true
        sessionDeadline = Date().addingTimeInterval(TimeInterval(duration))
        lastHeartbeat = Date()
        lock.unlock()

        os_log("session started, %d s limit", log: log, type: .info, duration)
        reply(nil)
    }

    func applyTargets(_ targetRPM: [NSNumber], reply: @escaping (Data?, String?) -> Void) {
        lock.lock()
        guard sessionActive else {
            lock.unlock()
            reply(nil, "No active session.")
            return
        }
        // This call *is* the heartbeat.
        lastHeartbeat = Date()
        if owningConnection == nil { owningConnection = NSXPCConnection.current() }
        lock.unlock()

        var failures: [String] = []
        for (index, value) in targetRPM.enumerated() where index < fans.fanCount {
            do {
                try fans.setForcedTarget(index, rpm: value.doubleValue)
            } catch {
                failures.append("fan \(index): \(error)")
            }
        }

        if !failures.isEmpty {
            os_log("apply failed: %{public}@", log: log, type: .error,
                   failures.joined(separator: "; "))
            reply(nil, failures.joined(separator: "; "))
            return
        }
        do {
            reply(try JSONEncoder().encode(makeSnapshot()), nil)
        } catch {
            reply(nil, "\(error)")
        }
    }

    func releaseControl(reply: @escaping (String?) -> Void) {
        lock.lock()
        sessionActive = false
        sessionDeadline = nil
        owningConnection = nil
        lock.unlock()

        let errors = fans.releaseAll()
        os_log("session ended by client", log: log, type: .info)
        reply(errors.isEmpty ? nil : errors.map { "\($0)" }.joined(separator: "; "))
    }

    func uninstall(reply: @escaping (String?) -> Void) {
        emergencyRelease()
        os_log("uninstalling", log: log, type: .default)
        reply(nil)

        // Booting ourselves out kills this process, so hand the work to a
        // detached shell and let the reply flush first.
        let script = """
        sleep 1
        /bin/rm -f '\(HelperInfo.launchDaemonPlistPath)'
        /bin/rm -f '\(HelperInfo.installedBinaryPath)'
        /bin/launchctl bootout system/\(HelperInfo.daemonLabel)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
    }
}
