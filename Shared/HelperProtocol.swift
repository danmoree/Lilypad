//
//  HelperProtocol.swift
//  Lilypad
//
//  The contract between Lilypad.app and the privileged helper daemon.
//
//  Design note: the app is the only thing that reads sensors and decides on a
//  fan speed; the helper is a deliberately dumb actuator. It knows nothing
//  about temperatures or targets. That keeps the root-privileged surface as
//  small as possible — it can raise or lower a fan within the firmware's own
//  limits, and nothing else.
//

import Foundation

nonisolated enum HelperInfo {
    /// Bumped whenever the XPC contract or helper behaviour changes; the app
    /// compares this against the running helper and reinstalls on mismatch.
    static let version = "1.0.0"

    static let machServiceName = "com.lilypad.helper"
    static let daemonLabel = "com.lilypad.helper"

    static let installedBinaryPath = "/Library/PrivilegedHelperTools/com.lilypad.helper"
    static let launchDaemonPlistPath = "/Library/LaunchDaemons/com.lilypad.helper.plist"

    /// Path of the helper binary inside the app bundle, relative to the bundle root.
    static let bundledHelperSubpath = "Contents/Library/PrivilegedHelperTools/com.lilypad.helper"

    /// The bundle identifier the helper requires of anything connecting to it.
    static let clientBundleIdentifier = "com.danielmoreno.projects.Lilypad"

    /// Team identifier the client's signature must carry. Combined with the
    /// Apple anchor this stops another local process impersonating the app.
    static let clientTeamIdentifier = "J722DG3N7J"

    /// Hard ceiling on any cooling session, independent of what the app asks
    /// for. Even a buggy or hostile client cannot hold the fans longer than this.
    static let absoluteMaxSessionSeconds = 60 * 60

    /// If the app stops heartbeating for this long the helper assumes it died
    /// and hands the fans back to the firmware.
    static let heartbeatTimeoutSeconds: TimeInterval = 8
}

/// Remote interface vended by the helper over XPC.
///
/// Every call replies with an optional error string rather than throwing, since
/// errors have to cross the process boundary.
@objc nonisolated protocol LilypadHelperProtocol {

    /// Returns the running helper's version. Used to detect a stale install.
    func handshake(reply: @escaping (String) -> Void)

    /// Current fan state, as JSON-encoded `FanSnapshot`.
    func readSnapshot(reply: @escaping (Data?, String?) -> Void)

    /// Starts a cooling session. `maxDurationSeconds` is clamped to
    /// `HelperInfo.absoluteMaxSessionSeconds`.
    func beginSession(maxDurationSeconds: Int, reply: @escaping (String?) -> Void)

    /// Sets each fan's target RPM and refreshes the heartbeat in one round trip.
    /// `targetRPM[i]` applies to fan `i`; values are clamped by the helper to
    /// the firmware's own limits. Returns a fresh snapshot.
    func applyTargets(_ targetRPM: [NSNumber], reply: @escaping (Data?, String?) -> Void)

    /// Ends the session and returns every fan to firmware control.
    func releaseControl(reply: @escaping (String?) -> Void)

    /// Releases the fans, then unloads and deletes the daemon.
    func uninstall(reply: @escaping (String?) -> Void)
}
