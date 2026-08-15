//
//  ThermalMonitor.swift
//  Lilypad
//
//  Samples the SMC's temperature sensors and derives the one number the app
//  actually cares about: how hot the bottom case is.
//
//  All SMC access here is read-only, which needs no privileges at all — the
//  helper is only involved once we want to *change* something.
//

import Foundation
import Observation

nonisolated struct SensorReading: Identifiable, Sendable {
    let key: String
    let label: String
    let role: SensorRole
    let celsius: Double

    var id: String { key }
}

/// How the current case temperature would feel against skin over a long sitting.
///
/// The boundaries follow the usual contact-comfort guidance: skin stops reading
/// a surface as neutral somewhere around 33 °C, and prolonged contact with
/// anything past roughly 42 °C is where low-temperature burn advice starts.
nonisolated enum LapComfort: String, Sendable {
    case cool = "Cool"
    case comfortable = "Comfortable"
    case warm = "Warm"
    case hot = "Hot"
    case tooHot = "Too hot"

    init(celsius: Double) {
        switch celsius {
        case ..<30: self = .cool
        case ..<34: self = .comfortable
        case ..<38: self = .warm
        case ..<42: self = .hot
        default: self = .tooHot
        }
    }

    var isUncomfortable: Bool { self == .hot || self == .tooHot }
}

/// Does the actual SMC polling. Lives off the main actor so a slow IOKit round
/// trip can never stutter the menu.
nonisolated final class SensorSampler: @unchecked Sendable {

    private let smc = SMCConnection()
    private let fanController: FanController
    private var available: [SensorDefinition] = []
    private var openError: String?

    init() {
        fanController = FanController(smc: smc)
        do {
            try smc.open()
            available = SensorCatalog.all.filter { definition in
                guard let value = smc.readNumber(definition.key) else { return false }
                return SensorCatalog.isPlausible(value)
            }
        } catch {
            openError = "\(error)"
        }
    }

    var failureReason: String? { openError }
    var supportsFanControl: Bool { fanController.supportsControl() }
    var fanCount: Int { fanController.fanCount }

    func sample() -> ([SensorReading], [FanState]) {
        let readings = available.compactMap { definition -> SensorReading? in
            guard let value = smc.readNumber(definition.key),
                  SensorCatalog.isPlausible(value) else { return nil }
            return SensorReading(key: definition.key, label: definition.label,
                                 role: definition.role, celsius: value)
        }
        return (readings, fanController.allStates())
    }

    /// The firmware's own target speed for each fan, sampled before we take
    /// over. Once a fan is forced this key reflects our value instead, so the
    /// engine captures it at engage time and uses it as a floor.
    func firmwareTargets() -> [Double] {
        fanController.allStates().map(\.targetRPM)
    }
}

@Observable
final class ThermalMonitor {

    private(set) var readings: [SensorReading] = []
    private(set) var fans: [FanState] = []
    /// Rolling history of the lap temperature for the menu's sparkline.
    private(set) var history: [Double] = []
    private(set) var failureReason: String?
    private(set) var supportsFanControl = false

    /// Sensor keys contributing to the lap reading. Defaults to the case and
    /// battery sensors; the user can widen this to the other enclosure sensors.
    var lapSensorKeys: Set<String>

    private let sampler = SensorSampler()
    private var timer: Timer?
    private var isSampling = false

    private static let historyLimit = 90

    init(lapSensorKeys: Set<String>? = nil) {
        self.lapSensorKeys = lapSensorKeys ?? Set(SensorCatalog.lapDefaults.map(\.key))
        failureReason = sampler.failureReason
        supportsFanControl = sampler.supportsFanControl
    }

    // MARK: Derived values

    /// The number the whole app revolves around: the hottest of the sensors
    /// sitting against the bottom case.
    var lapTemperature: Double? {
        let values = readings.filter { lapSensorKeys.contains($0.key) }.map(\.celsius)
        return values.max()
    }

    /// Hottest silicon sensor, used only as a safety interlock.
    var dieTemperature: Double? {
        readings.filter { $0.role == .die }.map(\.celsius).max()
    }

    var comfort: LapComfort? {
        lapTemperature.map(LapComfort.init(celsius:))
    }

    var availableSensors: [SensorReading] { readings }

    // MARK: Sampling

    func start(interval: TimeInterval = 2.0) {
        guard timer == nil else { return }
        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !isSampling else { return }
        isSampling = true
        let sampler = self.sampler
        Task.detached(priority: .utility) {
            let (readings, fans) = sampler.sample()
            await MainActor.run { [weak self] in
                self?.apply(readings: readings, fans: fans)
            }
        }
    }

    private func apply(readings: [SensorReading], fans: [FanState]) {
        self.readings = readings
        self.fans = fans
        if let lap = lapTemperature {
            history.append(lap)
            if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        }
        isSampling = false
    }

    func firmwareFanTargets() -> [Double] { sampler.firmwareTargets() }
}
