//
//  LilypadApp.swift
//  Lilypad
//
//  Created by Daniel Moreno on 8/14/26.
//

import SwiftUI
import Observation

/// Owns the long-lived objects and the timers that drive them.
///
/// A shared instance rather than plain `@State` so the app delegate can start
/// sampling at launch — the menu bar has to show a temperature before anyone
/// opens the menu.
@Observable
final class AppModel {

    static let shared = AppModel()

    let preferences: Preferences
    let monitor: ThermalMonitor
    let helper: HelperClient
    let engine: CoolingEngine

    @ObservationIgnored private var houseKeeping: Timer?

    private init() {
        let preferences = Preferences()
        let monitor = ThermalMonitor(lapSensorKeys: preferences.lapSensorKeys)
        let helper = HelperClient()

        self.preferences = preferences
        self.monitor = monitor
        self.helper = helper
        self.engine = CoolingEngine(monitor: monitor, helper: helper, preferences: preferences)
    }

    func start() {
        monitor.start(interval: 2)

        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            // Added to the main run loop below, so this always fires on the
            // main thread — no need to hop through a Task to reach the actor.
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        houseKeeping = timer

        Task { await helper.refreshStatus() }
    }

    private func tick() {
        // Keep the sensor selection in step with the preference.
        let keys = preferences.lapSensorKeys
        if monitor.lapSensorKeys != keys { monitor.lapSensorKeys = keys }
        engine.considerAutoEngage()
    }

    /// Text shown next to the pad in the menu bar.
    var menuBarLabel: String? {
        guard preferences.showTemperatureInMenuBar,
              let temperature = monitor.lapTemperature else { return nil }
        return preferences.format(temperature, decimals: 1)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
    }

    /// Handing the fans back on the way out is a courtesy, not a safety net —
    /// the helper releases them anyway as soon as our XPC connection drops.
    func applicationWillTerminate(_ notification: Notification) {
        let engine = AppModel.shared.engine
        if engine.phase.isActive { engine.disengage() }
    }
}

@main
struct LilypadApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private var model: AppModel { AppModel.shared }

    var body: some Scene {
        MenuBarExtra {
            MenuView(preferences: model.preferences,
                     monitor: model.monitor,
                     engine: model.engine,
                     helper: model.helper)
        } label: {
            Image(nsImage: PadIcon.statusItemImage(
                progress: model.engine.progress,
                active: model.engine.phase.isActive,
                reachedTarget: model.engine.hasReachedTarget,
                label: model.menuBarLabel))
        }
        .menuBarExtraStyle(.window)
    }
}
