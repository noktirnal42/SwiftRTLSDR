// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRKit
import RTLSDRServer

/// `serve`: an rtl_tcp server for the dongle, until Ctrl-C.
func serve(_ arguments: Arguments) -> Never {
    // Options first, so a typo is reported before the dongle is opened.
    var configuration = RTLTCPServer.Configuration()
    configuration.address = arguments.option("address") ?? "127.0.0.1"
    configuration.port = arguments.port("port", default: 1234)
    configuration.allowBiasTee = arguments.flag("allow-bias-tee")
    let rate = arguments.int("rate", default: 2_048_000)
    let frequency = Int(arguments.double("freq", default: 100e6))
    do {
        let device = try arguments.openDevice()
        try device.setSampleRate(rate)
        try arguments.applyFrequencyCorrection(to: device)
        try device.setCenterFrequency(frequency)
        try arguments.applyGain(to: device)
        try arguments.applyRetuneShortcuts(to: device)

        let address = configuration.address
        let server = RTLTCPServer(backend: device, configuration: configuration) { event in
            switch event {
            case let .listening(port): print("listening on \(address):\(port)")
            case let .clientConnected(peer): print("client \(peer) connected")
            case let .clientRejected(peer): print("client \(peer) turned away (one client at a time)")
            case let .clientDisconnected(peer, reason): print("client \(peer) left: \(reason)")
            case let .command(command, outcome): print("  \(command): \(outcome)")
            }
        }
        if configuration.address != "127.0.0.1" {
            print("warning: rtl_tcp has no authentication; anyone who can reach this port can use the dongle")
        }
        try server.start()

        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler {
            server.stop()
            let statistics = server.statistics
            print("\nserved \(statistics.clientsServed) client(s), sent \(statistics.bytesSent) bytes, dropped \(statistics.droppedBytes)")
            device.close()
            exit(0)
        }
        interrupt.resume()
        dispatchMain()
    } catch { fail(error.localizedDescription) }
}
