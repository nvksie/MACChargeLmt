import AppKit
import ServiceManagement

let arguments = CommandLine.arguments

if arguments.contains("--preflight-install") {
    do {
        try LegacyDaemonInstaller.preflight()
        print("install-preflight=ok")
    } catch {
        print("install-preflight=failed: \(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}

if arguments.contains("--uninstall-service") {
    let service = SMAppService.daemon(
        plistName: "com.nvksie.chargelmt.daemon.plist"
    )
    do {
        if LegacyDaemonInstaller.isInstalled {
            try LegacyDaemonInstaller.uninstall()
            print("legacy-unregistered")
            exit(0)
        }

        if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
        try LegacyDaemonInstaller.uninstall()
        print("unregistered")
    } catch {
        print("uninstall failed: \(error)")
        exit(1)
    }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
