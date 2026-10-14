import Foundation
import os
import AppKit
import os

if CommandLine.arguments.contains("--check") {
    guard let smc = try? SMCCommunicator() else {
        print("smc-unavailable")
        exit(1)
    }

    let architecture = PowerController.hardwareArchitecture
    guard let backend = PowerController.detectChargeBackend(
        smc: smc,
        architecture: architecture
    ) else {
        if CommandLine.arguments.contains("--verbose") {
            print("architecture=\(architecture)")
        }
        print("unsupported")
        exit(1)
    }

    let adapterSupported = SMCPowerKeys.adapterKeys.contains {
        smc.isKeyAvailable(key: $0.info.key, size: $0.info.dataSize)
    }
    if CommandLine.arguments.contains("--verbose") {
        print("architecture=\(architecture)")
        print("backend=\(backend.name)")
        print("discharge=\(adapterSupported ? "supported" : "unsupported")")
    }
    print("supported")
    exit(0)
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let controller: PowerController

    init(controller: PowerController) {
        self.controller = controller
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(
            with: ChargeDaemonProtocol.self
        )
        newConnection.exportedObject = DaemonService(controller: controller)
        newConnection.resume()
        return true
    }
}

private final class DaemonService: NSObject, ChargeDaemonProtocol {
    private let controller: PowerController

    init(controller: PowerController) {
        self.controller = controller
    }

    func status(reply: @escaping (NSDictionary) -> Void) {
        reply(controller.status())
    }

    func setLimits(
        minCharge: Int,
        maxCharge: Int,
        reply: @escaping (Bool) -> Void
    ) {
        reply(controller.setLimits(minCharge: minCharge, maxCharge: maxCharge))
    }

    func setMode(_ mode: String, reply: @escaping (Bool) -> Void) {
        reply(controller.setMode(mode))
    }
}

guard let controller = PowerController() else {
    os_log("This Mac does not expose supported Apple Silicon charge-control SMC keys")
    exit(1)
}

private let delegate = ListenerDelegate(controller: controller)
let listener = NSXPCListener(machServiceName: DaemonMachService.name)
listener.delegate = delegate
listener.resume()

let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
signal(SIGTERM, SIG_IGN)
signalSource.setEventHandler {
    controller.shutdown()
    exit(0)
}
signalSource.resume()

RunLoop.main.run()
