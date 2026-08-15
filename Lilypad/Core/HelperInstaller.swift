//
//  HelperInstaller.swift
//  Lilypad
//
//  Installs the privileged helper as a LaunchDaemon.
//
//  The install runs once, behind the standard macOS administrator prompt. The
//  whole script is base64-encoded into a single `do shell script` line rather
//  than written to a temp file — a root shell must never execute a script from
//  a location an unprivileged process could rewrite between us creating it and
//  root running it.
//
//  Before copying, the script checks the helper binary's signature against this
//  project's Team ID. That is what stops a tampered app bundle from getting a
//  binary of its choosing installed as root.
//

import Foundation

nonisolated enum InstallError: Error, CustomStringConvertible {
    case helperMissingFromBundle
    case cancelled
    case signatureRejected
    case scriptFailed(String)

    var description: String {
        switch self {
        case .helperMissingFromBundle:
            return "The helper tool is missing from the app bundle. Rebuild Lilypad."
        case .cancelled:
            return "Authorisation was cancelled."
        case .signatureRejected:
            return """
            The helper's code signature didn't match this project's Team ID \
            (\(HelperInfo.clientTeamIdentifier)). Build Lilypad with your own \
            signing identity, or update HelperInfo.clientTeamIdentifier to match it.
            """
        case .scriptFailed(let message):
            return message
        }
    }
}

nonisolated enum HelperInstaller {

    static var bundledHelperURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent(HelperInfo.bundledHelperSubpath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: HelperInfo.installedBinaryPath)
            && FileManager.default.fileExists(atPath: HelperInfo.launchDaemonPlistPath)
    }

    // MARK: Install

    /// Prompts for administrator rights and installs (or reinstalls) the daemon.
    @MainActor
    static func install() throws {
        guard let source = bundledHelperURL else { throw InstallError.helperMissingFromBundle }
        try runPrivileged(script: installScript(source: source.path))
    }

    @MainActor
    static func uninstall() throws {
        try runPrivileged(script: uninstallScript())
    }

    // MARK: Script construction

    private static func installScript(source: String) -> String {
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = "
            + "\"\(HelperInfo.clientTeamIdentifier)\""

        return """
        set -e
        SRC=\(shellQuote(source))

        # Refuse to install a binary that isn't signed by this project.
        if ! /usr/bin/codesign --verify --strict -R \(shellQuote("=" + requirement)) "$SRC" 2>/dev/null; then
          echo "LILYPAD_SIGNATURE_REJECTED" >&2
          exit 90
        fi

        /bin/mkdir -p /Library/PrivilegedHelperTools
        /bin/launchctl bootout system/\(HelperInfo.daemonLabel) 2>/dev/null || true

        /bin/cp -f "$SRC" \(shellQuote(HelperInfo.installedBinaryPath))
        /usr/sbin/chown root:wheel \(shellQuote(HelperInfo.installedBinaryPath))
        /bin/chmod 544 \(shellQuote(HelperInfo.installedBinaryPath))

        /bin/cat > \(shellQuote(HelperInfo.launchDaemonPlistPath)) <<'LILYPAD_PLIST'
        \(launchDaemonPlist)
        LILYPAD_PLIST
        /usr/sbin/chown root:wheel \(shellQuote(HelperInfo.launchDaemonPlistPath))
        /bin/chmod 644 \(shellQuote(HelperInfo.launchDaemonPlistPath))

        /bin/launchctl bootstrap system \(shellQuote(HelperInfo.launchDaemonPlistPath))
        """
    }

    private static func uninstallScript() -> String {
        """
        /bin/launchctl bootout system/\(HelperInfo.daemonLabel) 2>/dev/null || true
        /bin/rm -f \(shellQuote(HelperInfo.launchDaemonPlistPath))
        /bin/rm -f \(shellQuote(HelperInfo.installedBinaryPath))
        exit 0
        """
    }

    /// `KeepAlive` matters for safety rather than convenience: it keeps the
    /// watchdog resident, so if the app is force-quit mid-session there is
    /// still a live process to notice the missing heartbeat and hand the fans
    /// back to the firmware.
    private static var launchDaemonPlist: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(HelperInfo.daemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(HelperInfo.installedBinaryPath)</string>
            </array>
            <key>MachServices</key>
            <dict>
                <key>\(HelperInfo.machServiceName)</key>
                <true/>
            </dict>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ThrottleInterval</key>
            <integer>5</integer>
            <key>ProcessType</key>
            <string>Background</string>
        </dict>
        </plist>
        """
    }

    // MARK: Privileged execution

    @MainActor
    private static func runPrivileged(script: String) throws {
        let encoded = Data(script.utf8).base64EncodedString()
        // Base64 keeps the payload to a single line of [A-Za-z0-9+/=], which
        // sidesteps every quoting hazard in AppleScript string literals.
        let command = "echo \(encoded) | /usr/bin/base64 -D | /bin/sh"
        let source = "do shell script \"\(command)\" with administrator privileges"

        guard let appleScript = NSAppleScript(source: source) else {
            throw InstallError.scriptFailed("Could not build the installation script.")
        }

        var errorInfo: NSDictionary?
        appleScript.executeAndReturnError(&errorInfo)

        guard let errorInfo else { return }

        let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
        let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "Unknown error"

        // -128 is the standard "user cancelled" from the authorisation dialog.
        if code == -128 { throw InstallError.cancelled }
        if code == 90 || message.contains("LILYPAD_SIGNATURE_REJECTED") {
            throw InstallError.signatureRejected
        }
        throw InstallError.scriptFailed(message)
    }

    /// Wraps a value in single quotes for /bin/sh, escaping embedded quotes.
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
