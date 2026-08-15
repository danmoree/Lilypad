//
//  MenuView.swift
//  Lilypad
//
//  The panel that drops out of the menu bar.
//

import SwiftUI

struct MenuView: View {

    @Bindable var preferences: Preferences
    var monitor: ThermalMonitor
    var engine: CoolingEngine
    var helper: HelperClient

    @State private var isInstalling = false
    @State private var installMessage: String?
    @State private var showSensors = false

    private static let panelWidth: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let reason = monitor.failureReason {
                Notice(icon: "exclamationmark.triangle", tone: .warning,
                       title: "Can't read sensors", message: reason)
            } else if !monitor.supportsFanControl {
                Notice(icon: "fan.slash", tone: .warning,
                       title: "No controllable fans",
                       message: "This Mac doesn't expose writable fan controls. "
                              + "Lilypad can still show you temperatures.")
            } else if helper.status.isReady {
                padControl
                readout
                Divider()
                settings
            } else {
                setupSection
                readout
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: Self.panelWidth)
        .task {
            await helper.refreshStatus()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            PadShape()
                .fill(Color.accentColor.gradient)
                .frame(width: 16, height: 16)
            Text("Lilypad")
                .font(.headline)
            Spacer()
            if engine.phase.isActive {
                Text(timeString(engine.secondsRemaining))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: The pad

    private var padControl: some View {
        VStack(spacing: 10) {
            Button {
                if engine.phase.isActive {
                    engine.disengage()
                } else {
                    engine.engage()
                }
            } label: {
                PadButtonFace(progress: engine.progress,
                              isActive: engine.phase.isActive,
                              temperature: monitor.lapTemperature,
                              preferences: preferences)
            }
            .buttonStyle(.plain)

            Text(statusLine)
                .font(.callout)
                .foregroundStyle(engine.phase.isActive ? .primary : .secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            if engine.isStalled {
                Notice(icon: "flame", tone: .warning,
                       title: "Too much heat to keep up", message: stallMessage)
            }
            if let error = engine.lastError {
                Notice(icon: "exclamationmark.triangle", tone: .warning,
                       title: "Fan control interrupted", message: error)
            }
        }
    }

    /// Says what the fans are actually doing rather than assuming full speed —
    /// the advice differs completely depending on whether there's headroom left
    /// on the noise slider.
    private var stallMessage: String {
        if !engine.isAtFullSpeed {
            return "The workload is making heat faster than the fans can remove it "
                 + "at this noise level. Turn Fan noise up, or pick a higher target."
        }
        return "Even at full speed the fans can't remove heat as fast as the "
             + "workload is making it. Pick a higher target, or ease off what's running."
    }

    private var statusLine: String {
        switch engine.phase {
        case .idle:
            guard let comfort = monitor.comfort else { return "Reading sensors…" }
            return comfort.isUncomfortable
                ? "Your lap deserves better. Tap the pad."
                : "Tap the pad to cool things down."
        case .preparing:
            return "Taking control of the fans…"
        case .cooling:
            return "Cooling · \(timeString(engine.secondsRemaining)) left"
        case .settling:
            return "Almost there · holding at target"
        case .finished(let outcome):
            switch outcome {
            case .reachedTarget(let seconds):
                return "Comfortable again, in \(timeString(seconds))."
            case .timeLimit:
                return "Time's up — fans back to automatic."
            case .stoppedByUser:
                return "Stopped. Fans back to automatic."
            case .failed(let message):
                return message
            }
        }
    }

    // MARK: Readout

    private var readout: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !monitor.history.isEmpty {
                Sparkline(values: monitor.history, target: preferences.targetCelsius)
                    .frame(height: 34)
            }

            HStack {
                Label {
                    Text(fanSummary)
                } icon: {
                    Image(systemName: "fan")
                        .symbolEffect(.rotate, options: .repeat(.continuous),
                                      isActive: engine.phase.isActive)
                }
                Spacer()
                Button {
                    showSensors.toggle()
                } label: {
                    Text(showSensors ? "Hide sensors" : "Sensors")
                }
                .buttonStyle(.link)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if showSensors {
                SensorList(readings: monitor.availableSensors,
                           lapKeys: monitor.lapSensorKeys,
                           preferences: preferences)
            }
        }
    }

    private var fanSummary: String {
        let fans = monitor.fans
        guard !fans.isEmpty else { return "No fans detected" }
        // Each fan has its own ceiling, so show them all — a single "max" reads
        // as though a fan is underperforming when it's already flat out.
        let speeds = fans.map { "\(Int($0.actualRPM))" }.joined(separator: " · ")
        let ceilings = fans.map { "\(Int($0.maxRPM))" }.joined(separator: " · ")
        return "\(speeds) RPM  (max \(ceilings))"
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledSlider(
                title: "Target",
                value: $preferences.targetCelsius,
                range: preferences.targetRange,
                step: 0.5,
                caption: preferences.formatWithUnit(preferences.targetCelsius, decimals: 0)
            )

            LabeledSlider(
                title: "Fan noise",
                value: $preferences.intensity,
                range: 0.3...1.0,
                step: 0.05,
                caption: intensityLabel
            )

            HStack {
                Text("Give up after")
                    .font(.caption)
                Spacer()
                Picker("", selection: $preferences.maxMinutes) {
                    ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { minutes in
                        Text("\(minutes) min").tag(minutes)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 90)
            }

            Toggle(isOn: $preferences.autoEngage) {
                Text("Start automatically above \(preferences.formatWithUnit(preferences.autoEngageCelsius, decimals: 0))")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)

            if preferences.autoEngage {
                LabeledSlider(
                    title: "Trigger",
                    value: $preferences.autoEngageCelsius,
                    range: 34...46,
                    step: 0.5,
                    caption: preferences.formatWithUnit(preferences.autoEngageCelsius, decimals: 0)
                )
            }
        }
    }

    private var intensityLabel: String {
        switch preferences.intensity {
        case ..<0.45: return "Quiet"
        case ..<0.7: return "Moderate"
        case ..<0.9: return "Strong"
        default: return "Maximum"
        }
    }

    // MARK: Helper setup

    @ViewBuilder
    private var setupSection: some View {
        switch helper.status {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking fan control…").font(.callout)
            }
        case .notInstalled, .needsUpdate, .unavailable:
            VStack(alignment: .leading, spacing: 10) {
                Notice(icon: "lock.shield", tone: .info,
                       title: setupTitle, message: setupMessage)

                Button {
                    Task { await runInstall() }
                } label: {
                    if isInstalling {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Installing…")
                        }
                    } else {
                        Text(setupButtonTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isInstalling)

                if let installMessage {
                    Text(installMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .ready:
            EmptyView()
        }
    }

    private var setupTitle: String {
        switch helper.status {
        case .needsUpdate: return "Helper needs updating"
        case .unavailable: return "Helper isn't responding"
        default: return "One-time setup"
        }
    }

    private var setupMessage: String {
        switch helper.status {
        case .needsUpdate(let installed):
            return "The installed helper is version \(installed); this build expects "
                 + "\(HelperInfo.version)."
        case .unavailable(let reason):
            return reason
        default:
            return "Changing fan speed needs a small background service running as "
                 + "an administrator. You'll be asked for your password once."
        }
    }

    private var setupButtonTitle: String {
        switch helper.status {
        case .needsUpdate, .unavailable: return "Repair fan control"
        default: return "Enable fan control"
        }
    }

    private func runInstall() async {
        isInstalling = true
        installMessage = nil
        do {
            try HelperInstaller.install()
            // launchd needs a beat to bootstrap the daemon before it answers.
            try? await Task.sleep(for: .milliseconds(700))
            await helper.refreshStatus()
            if case .ready = helper.status {} else {
                installMessage = "Installed, but the helper still isn't answering. "
                               + "Check Console.app for com.lilypad.helper."
            }
        } catch InstallError.cancelled {
            // Nothing to report — the user closed the password prompt.
        } catch {
            installMessage = "\(error)"
        }
        isInstalling = false
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Menu {
                Toggle("Show temperature in menu bar",
                       isOn: $preferences.showTemperatureInMenuBar)
                Toggle("Use Fahrenheit", isOn: $preferences.useFahrenheit)
                Toggle("Include extra enclosure sensors",
                       isOn: $preferences.includeExtraSensors)
                Divider()
                Button("Remove helper…") {
                    Task {
                        try? await helper.uninstall()
                        await helper.refreshStatus()
                    }
                }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            Button("Quit Lilypad") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func timeString(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Pad button

private struct PadButtonFace: View {
    let progress: Double
    let isActive: Bool
    let temperature: Double?
    let preferences: Preferences

    @State private var isHovering = false

    var body: some View {
        ZStack {
            PadShape()
                .fill(Color.secondary.opacity(0.12))

            // Fills from the bottom as the case cools.
            PadShape()
                .fill(Color.green.gradient)
                .mask(alignment: .bottom) {
                    GeometryReader { geometry in
                        Rectangle()
                            .frame(height: geometry.size.height * (isActive ? progress : 0))
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
                .animation(.easeInOut(duration: 0.6), value: progress)

            PadShape()
                .stroke(isActive ? Color.green : Color.secondary.opacity(0.5), lineWidth: 2)

            VStack(spacing: 0) {
                if let temperature {
                    Text(preferences.format(temperature, decimals: 1))
                        .font(.system(size: 26, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    Text(LapComfort(celsius: temperature).rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("—").font(.system(size: 26, weight: .medium, design: .rounded))
                }
            }
            .offset(x: -2)
        }
        .frame(width: 116, height: 116)
        .scaleEffect(isHovering ? 1.03 : 1.0)
        .animation(.spring(duration: 0.25), value: isHovering)
        .onHover { isHovering = $0 }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .help(isActive ? "Stop cooling" : "Start cooling")
    }
}

// MARK: - Small components

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let caption: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .frame(width: 62, alignment: .leading)
            Slider(value: $value, in: range, step: step)
                .controlSize(.small)
            Text(caption)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
        }
    }
}

private struct Notice: View {
    enum Tone { case info, warning }

    let icon: String
    let tone: Tone
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tone == .warning ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.medium))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct Sparkline: View {
    let values: [Double]
    let target: Double

    var body: some View {
        GeometryReader { geometry in
            let bounds = range
            let span = max(bounds.upperBound - bounds.lowerBound, 1)

            ZStack {
                // Target line.
                let targetY = yPosition(for: target, in: geometry.size, bounds: bounds, span: span)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: targetY))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: targetY))
                }
                .stroke(Color.green.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                Path { path in
                    for (index, value) in values.enumerated() {
                        let x = geometry.size.width * Double(index) / Double(max(values.count - 1, 1))
                        let y = yPosition(for: value, in: geometry.size, bounds: bounds, span: span)
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5,
                                                              lineCap: .round,
                                                              lineJoin: .round))
            }
        }
    }

    /// Always include the target so the dashed line stays on screen, and pad by
    /// a degree so a flat trace doesn't collapse onto the edge.
    private var range: ClosedRange<Double> {
        let lower = min(values.min() ?? target, target) - 1
        let upper = max(values.max() ?? target, target) + 1
        return lower...upper
    }

    private func yPosition(for value: Double, in size: CGSize,
                           bounds: ClosedRange<Double>, span: Double) -> CGFloat {
        size.height * (1 - (value - bounds.lowerBound) / span)
    }
}

private struct SensorList: View {
    let readings: [SensorReading]
    let lapKeys: Set<String>
    let preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(grouped, id: \.0) { role, items in
                Text(title(for: role))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                ForEach(items) { reading in
                    HStack(spacing: 4) {
                        if lapKeys.contains(reading.key) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 5))
                                .foregroundStyle(.green)
                        } else {
                            Color.clear.frame(width: 5, height: 5)
                        }
                        Text(reading.label)
                        Spacer()
                        Text(preferences.formatWithUnit(reading.celsius))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                }
            }
            Text("Green dots feed the lap reading.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }

    private var grouped: [(String, [SensorReading])] {
        let order: [SensorRole] = [.skin, .battery, .die, .other]
        return order.compactMap { role in
            let items = readings.filter { $0.role == role }
            return items.isEmpty ? nil : (role.rawValue, items)
        }
    }

    private func title(for role: String) -> String {
        switch role {
        case "skin": return "Enclosure"
        case "battery": return "Battery"
        case "die": return "Silicon"
        default: return "Other"
        }
    }
}
