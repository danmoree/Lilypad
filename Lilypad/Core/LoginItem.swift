//
//  LoginItem.swift
//  Lilypad
//
//  Opening Lilypad at login, via `SMAppService.mainApp`.
//
//  There is deliberately no preference backing this. macOS owns the setting —
//  the user can turn it off in System Settings → General → Login Items without
//  telling us — so the service's own status is read back rather than mirrored
//  into UserDefaults, where the two could disagree.
//
//  Registration is per app bundle *path*. A copy run from DerivedData and a
//  copy in /Applications are two different login items, which is why the app
//  should be installed before this is switched on.
//

import Foundation
import ServiceManagement

nonisolated enum LoginItem {

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    /// Registered, but macOS is waiting for the user to allow it in System
    /// Settings. This is the normal state after the very first `register()`
    /// if the user has previously disabled a Lilypad login item by hand.
    static var needsApproval: Bool { status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }

    @MainActor
    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
