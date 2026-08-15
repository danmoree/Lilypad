//
//  main.swift
//  LilypadHelper
//
//  Entry point for the root LaunchDaemon.
//
//  Nothing here touches AppKit or the window server; this process exists only
//  to hold an XPC listener and write two SMC keys per fan.
//

import Foundation
import os.log

private let bootLog = OSLog(subsystem: "com.lilypad.helper", category: "main")

let service = HelperService()

do {
    try service.start()
} catch {
    os_log("failed to start: %{public}@", log: bootLog, type: .fault, "\(error)")
    exit(EXIT_FAILURE)
}

// Return the fans to the firmware on any orderly shutdown. launchd sends
// SIGTERM when the daemon is booted out; SIGINT covers running it by hand for
// debugging. SIGKILL cannot be trapped, which is why HelperService also
// releases orphaned fans on its next launch.
var signalSources: [DispatchSourceSignal] = []

for signalNumber in [SIGTERM, SIGINT] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber,
                                                 queue: .global(qos: .userInitiated))
    source.setEventHandler {
        os_log("caught signal %d, releasing fans", log: bootLog, type: .default, signalNumber)
        service.emergencyRelease()
        exit(EXIT_SUCCESS)
    }
    source.resume()
    // Sources are only retained by this loop iteration; keep them alive forever.
    signalSources.append(source)
}

let listener = NSXPCListener(machServiceName: HelperInfo.machServiceName)
listener.delegate = service
listener.resume()

os_log("listening on %{public}@", log: bootLog, type: .info, HelperInfo.machServiceName)
RunLoop.main.run()
