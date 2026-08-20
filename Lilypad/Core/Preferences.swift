//
//  Preferences.swift
//  Lilypad
//

import Foundation
import Observation

@Observable
final class Preferences {

    private let defaults = UserDefaults.standard

    /// Case temperature we're aiming to reach, in °C.
    ///
    /// 34 °C is the default because it sits just past the point where skin
    /// stops registering a surface as neutral — cool enough to be pleasant on
    /// bare legs, but not so low that the fans run forever chasing it.
    var targetCelsius: Double {
        didSet { defaults.set(targetCelsius, forKey: Keys.target) }
    }

    /// Longest a single cooling session may run, in minutes.
    var maxMinutes: Int {
        didSet { defaults.set(maxMinutes, forKey: Keys.maxMinutes) }
    }

    /// How much of the fans' range we're willing to use, 0...1. This is the
    /// noise dial: 1.0 is the firmware's maximum, which on this machine is a
    /// very audible ~5300 RPM.
    var intensity: Double {
        didSet { defaults.set(intensity, forKey: Keys.intensity) }
    }

    /// Start cooling automatically when the case gets too warm.
    var autoEngage: Bool {
        didSet { defaults.set(autoEngage, forKey: Keys.autoEngage) }
    }

    /// Gap between the target and the temperature that starts a session on its
    /// own — ordinary thermostat hysteresis.
    ///
    /// It cannot be zero. A session ends the moment the case reaches the
    /// target, so if auto-engage also fired at the target the case would drift
    /// back over it within seconds and the fans would cycle on and off
    /// continuously. This is stored in Celsius but chosen to read as a round
    /// 3 °F, the unit most of the UI is set to; the cooldown after a session
    /// is what keeps a gap this narrow from short-cycling.
    static let autoEngageDeadband = 1.7

    /// Case temperature that starts a session automatically. Derived from the
    /// target so there is only one temperature to think about.
    var autoEngageCelsius: Double { targetCelsius + Self.autoEngageDeadband }

    var showTemperatureInMenuBar: Bool {
        didSet { defaults.set(showTemperatureInMenuBar, forKey: Keys.showTemp) }
    }

    var useFahrenheit: Bool {
        didSet { defaults.set(useFahrenheit, forKey: Keys.fahrenheit) }
    }

    /// Extra enclosure sensors folded into the lap reading beyond the defaults.
    var includeExtraSensors: Bool {
        didSet { defaults.set(includeExtraSensors, forKey: Keys.extraSensors) }
    }

    private enum Keys {
        static let target = "targetCelsius"
        static let maxMinutes = "maxMinutes"
        static let intensity = "intensity"
        static let autoEngage = "autoEngage"
        static let showTemp = "showTemperatureInMenuBar"
        static let fahrenheit = "useFahrenheit"
        static let extraSensors = "includeExtraSensors"
    }

    init() {
        defaults.register(defaults: [
            Keys.target: 34.0,
            Keys.maxMinutes: 15,
            Keys.intensity: 0.8,
            Keys.autoEngage: false,
            Keys.showTemp: true,
            Keys.fahrenheit: false,
            Keys.extraSensors: false,
        ])
        targetCelsius = defaults.double(forKey: Keys.target)
        maxMinutes = defaults.integer(forKey: Keys.maxMinutes)
        intensity = defaults.double(forKey: Keys.intensity)
        autoEngage = defaults.bool(forKey: Keys.autoEngage)
        showTemperatureInMenuBar = defaults.bool(forKey: Keys.showTemp)
        useFahrenheit = defaults.bool(forKey: Keys.fahrenheit)
        includeExtraSensors = defaults.bool(forKey: Keys.extraSensors)
    }

    var lapSensorKeys: Set<String> {
        var keys = Set(SensorCatalog.lapDefaults.map(\.key))
        if includeExtraSensors {
            keys.formUnion(SensorCatalog.enclosureExtras.filter { $0.role == .skin }.map(\.key))
        }
        return keys
    }

    // MARK: Formatting

    func format(_ celsius: Double, decimals: Int = 0) -> String {
        let value = useFahrenheit ? celsius * 9 / 5 + 32 : celsius
        return String(format: "%.\(decimals)f°", value)
    }

    func formatWithUnit(_ celsius: Double, decimals: Int = 1) -> String {
        let value = useFahrenheit ? celsius * 9 / 5 + 32 : celsius
        return String(format: "%.\(decimals)f°\(useFahrenheit ? "F" : "C")", value)
    }

    /// Formats a temperature *difference* rather than a reading.
    ///
    /// A delta scales by the 9/5 ratio alone — applying the +32 offset as well
    /// would render a 3 °C gap as "37 °F".
    func formatDelta(_ celsius: Double, decimals: Int = 0) -> String {
        let value = useFahrenheit ? celsius * 9 / 5 : celsius
        return String(format: "%.\(decimals)f°", value)
    }

    /// Slider bounds for the target, expressed in the display unit.
    var targetRange: ClosedRange<Double> { 28...42 }
}
