//
//  HelperClient.swift
//  Lilypad
//
//  App-side XPC connection to the privileged helper.
//

import Foundation
import Observation

nonisolated enum HelperStatus: Equatable, Sendable {
    case checking
    case notInstalled
    /// Installed, but built against a different version of the contract.
    case needsUpdate(installed: String)
    case ready
    case unavailable(String)

    var isReady: Bool { self == .ready }
}

nonisolated enum HelperError: Error, CustomStringConvertible {
    case notConnected
    case timedOut
    case remote(String)
    case badResponse

    var description: String {
        switch self {
        case .notConnected: return "The Lilypad helper isn't running."
        case .timedOut: return "The Lilypad helper stopped responding."
        case .remote(let message): return message
        case .badResponse: return "The Lilypad helper sent a malformed reply."
        }
    }
}

/// Ensures an XPC reply resumes its continuation exactly once. Both the reply
/// block and the timeout can fire for the same call, and resuming a checked
/// continuation twice is a hard crash.
private final class ReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<Data?, HelperError>, Never>?

    init(_ continuation: CheckedContinuation<Result<Data?, HelperError>, Never>) {
        self.continuation = continuation
    }

    func fire(_ value: Result<Data?, HelperError>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

@Observable
final class HelperClient {

    private(set) var status: HelperStatus = .checking

    @ObservationIgnored private var connection: NSXPCConnection?
    private static let callTimeout: TimeInterval = 5

    // MARK: Connection

    private func proxy() throws -> LilypadHelperProtocol {
        if connection == nil {
            let new = NSXPCConnection(machServiceName: HelperInfo.machServiceName,
                                      options: .privileged)
            new.remoteObjectInterface = NSXPCInterface(with: LilypadHelperProtocol.self)
            new.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            new.interruptionHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            new.resume()
            connection = new
        }
        guard let remote = connection?.remoteObjectProxyWithErrorHandler({ _ in })
                as? LilypadHelperProtocol
        else { throw HelperError.notConnected }
        return remote
    }

    func disconnect() {
        connection?.invalidate()
        connection = nil
    }

    /// Runs one XPC round trip with a timeout, so a wedged daemon surfaces as an
    /// error in the menu instead of a spinning UI.
    ///
    /// Deliberately non-generic. Every helper method is funnelled through the
    /// same `(Data?, String?)` reply shape and decoded by the caller: a generic
    /// version of this function crashes the Swift 6.3 optimiser with infinite
    /// recursion in the SIL inliner when the module is built `-O -wmo` under
    /// `-default-isolation MainActor`.
    private func perform(
        _ body: (LilypadHelperProtocol, @escaping (Data?, String?) -> Void) -> Void
    ) async -> Result<Data?, HelperError> {
        guard let remote = try? proxy() else { return .failure(.notConnected) }
        return await withCheckedContinuation { continuation in
            let gate = ReplyGate(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.callTimeout) {
                gate.fire(.failure(.timedOut))
            }
            body(remote) { data, message in
                if let message {
                    gate.fire(.failure(.remote(message)))
                } else {
                    gate.fire(.success(data))
                }
            }
        }
    }

    private func decodeSnapshot(_ result: Result<Data?, HelperError>) throws -> FanSnapshot {
        guard let data = try result.get(),
              let snapshot = try? JSONDecoder().decode(FanSnapshot.self, from: data)
        else { throw HelperError.badResponse }
        return snapshot
    }

    // MARK: Status

    func refreshStatus() async {
        guard FileManager.default.fileExists(atPath: HelperInfo.installedBinaryPath),
              FileManager.default.fileExists(atPath: HelperInfo.launchDaemonPlistPath)
        else {
            status = .notInstalled
            disconnect()
            return
        }

        let result = await perform { remote, finish in
            remote.handshake { version in finish(Data(version.utf8), nil) }
        }

        switch result {
        case .success(let data):
            let version = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            status = version == HelperInfo.version ? .ready : .needsUpdate(installed: version)
        case .failure(let error):
            // Files are on disk but nothing answered — usually a half-finished
            // install, or the daemon was booted out by hand.
            status = .unavailable(error.description)
        }
    }

    // MARK: Commands

    func beginSession(maxDurationSeconds: Int) async throws {
        let result = await perform { remote, finish in
            remote.beginSession(maxDurationSeconds: maxDurationSeconds) { finish(nil, $0) }
        }
        _ = try result.get()
    }

    @discardableResult
    func applyTargets(_ rpms: [Double]) async throws -> FanSnapshot {
        let numbers = rpms.map { NSNumber(value: $0) }
        let result = await perform { remote, finish in
            remote.applyTargets(numbers) { data, message in finish(data, message) }
        }
        return try decodeSnapshot(result)
    }

    func readSnapshot() async throws -> FanSnapshot {
        let result = await perform { remote, finish in
            remote.readSnapshot { data, message in finish(data, message) }
        }
        return try decodeSnapshot(result)
    }

    /// Best effort — used on teardown paths where there's nothing useful to do
    /// with a failure. The helper's watchdog covers us if this never lands.
    func releaseControl() async {
        _ = await perform { remote, finish in
            remote.releaseControl { finish(nil, $0) }
        }
    }

    func uninstall() async throws {
        let result = await perform { remote, finish in
            remote.uninstall { finish(nil, $0) }
        }
        disconnect()
        _ = try result.get()
    }
}
