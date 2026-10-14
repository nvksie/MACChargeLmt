import AppKit
import Combine
import ServiceManagement

func L(_ key: String) -> String {
    NSLocalizedString(key, comment: key)
}

final class AppModel: ObservableObject {
    @Published var minCharge = 60
    @Published var maxCharge = 80
    @Published var hasPendingLimitChanges = false
    @Published var percent = 0
    @Published var charging = false
    @Published var adapterConnected = false
    @Published var mode: ChargeMode = .normal
    @Published var daemonConnected = false
    @Published var supportsDischarge = false
    @Published var backend = L("未知")
    @Published var legacyDaemonInstalled = false
    @Published var daemonUpdateAvailable = false
    @Published var daemonError: String?
    @Published var loginItemEnabled = false
    @Published var daemonStatus: SMAppService.Status = .notRegistered
    @Published var loginItemBusy = false
    @Published var installBusy = false
    @Published var uninstallBusy = false
    @Published var installStage: String?

    private var connection: NSXPCConnection?
    private var remoteMinCharge = 60
    private var remoteMaxCharge = 80
    private var isConfirmingLimitChanges = false

    var statusText: String {
        guard daemonConnected else { return L("后台服务未连接") }
        let action: String
        switch mode {
        case .normal:
            action = charging ? L("充电中") : L("保持")
        case .chargeFull:
            action = L("充满一次中")
        case .dischargeToLimit:
            action = L("放电到上限中")
        }
        return String(
            format: L("生效：%1$lld%% · %2$@ · %3$lld%%-%4$lld%%"),
            percent,
            action,
            remoteMinCharge,
            remoteMaxCharge
        )
    }

    var shouldShowInstallMenuItem: Bool {
        if legacyDaemonInstalled {
            return LegacyDaemonInstaller.needsUpdate
        }
        return daemonStatus == .notRegistered
    }

    var canUninstallDaemon: Bool {
        daemonStatus == .enabled
            || daemonStatus == .requiresApproval
            || legacyDaemonInstalled
            || daemonConnected
    }

    init() {
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func refresh() {
        daemonStatus = SMAppService.daemon(
            plistName: "com.nvksie.chargelmt.daemon.plist"
        ).status
        legacyDaemonInstalled = LegacyDaemonInstaller.isInstalled
        daemonUpdateAvailable = legacyDaemonInstalled && LegacyDaemonInstaller.needsUpdate
        loginItemEnabled = SMAppService.mainApp.status == .enabled

        let proxy = remoteProxy
        proxy.status { [weak self] status in
            RunLoop.main.perform {
                guard let self else { return }
                let supported = (status["supported"] as? Bool) == true
                self.daemonConnected = supported
                self.supportsDischarge = status["supportsDischarge"] as? Bool ?? false
                self.backend = (status["backend"] as? String).map(L) ?? self.backend
                self.remoteMinCharge = status["minCharge"] as? Int ?? self.remoteMinCharge
                self.remoteMaxCharge = status["maxCharge"] as? Int ?? self.remoteMaxCharge
                if self.hasPendingLimitChanges {
                    if self.isConfirmingLimitChanges,
                       self.remoteMinCharge == self.minCharge,
                       self.remoteMaxCharge == self.maxCharge {
                        self.hasPendingLimitChanges = false
                        self.isConfirmingLimitChanges = false
                    }
                } else {
                    self.minCharge = self.remoteMinCharge
                    self.maxCharge = self.remoteMaxCharge
                }
                self.percent = status["percent"] as? Int ?? self.percent
                self.charging = status["charging"] as? Bool ?? false
                self.adapterConnected = status["adapterConnected"] as? Bool ?? false
                self.mode = ChargeMode(rawValue: status["mode"] as? String ?? "") ?? .normal
                self.daemonError = (status["error"] as? String).map(L)
            }
        }
    }

    func applyLimits() {
        clampLimits()
        hasPendingLimitChanges = true
        isConfirmingLimitChanges = false
        let min = minCharge
        let max = maxCharge
        remoteProxy.setLimits(minCharge: min, maxCharge: max) { [weak self] success in
            RunLoop.main.perform {
                self?.daemonConnected = success
                if success {
                    self?.isConfirmingLimitChanges = true
                }
                self?.refresh()
            }
        }
    }

    func setLocalMinCharge(_ value: Int) {
        minCharge = value
        clampLimits()
        hasPendingLimitChanges = true
        isConfirmingLimitChanges = false
    }

    func setLocalMaxCharge(_ value: Int) {
        maxCharge = value
        clampLimits()
        hasPendingLimitChanges = true
        isConfirmingLimitChanges = false
    }

    func requestMode(_ requestedMode: ChargeMode) {
        remoteProxy.setMode(requestedMode.rawValue) { [weak self] _ in
            RunLoop.main.perform { self?.refresh() }
        }
    }

    @MainActor func beginSetLoginItem(_ enabled: Bool) {
        guard !loginItemBusy else { return }
        loginItemBusy = true
        defer { loginItemBusy = false }

        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else if service.status != .notRegistered {
                try service.unregister()
            }

            if service.status == .requiresApproval {
                openLoginItemsSettings()
                daemonError = L("请在系统设置的“登录项与扩展”中允许 ChargeLmt")
            } else {
                daemonError = nil
            }
        } catch {
            daemonError = String(format: L("自启动设置失败：%@"), error.localizedDescription)
            presentInstallFailure(error, title: L("自启动设置失败"))
        }

        loginItemEnabled = service.status == .enabled
        refresh()
    }

    func beginInstall() {
        guard !installBusy else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L("安装 ChargeLmt 后台服务")
        alert.informativeText = L("service.install.explanation")
        alert.addButton(withTitle: L("安装"))
        alert.addButton(withTitle: L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            await startInstall()
        }
    }

    @MainActor private func startInstall() async {
        installBusy = true
        defer {
            installBusy = false
            installStage = nil
        }
        installStage = L("正在准备安装文件...")
        invalidateConnection()
        do {
#if DEBUG
            try LegacyDaemonInstaller.install()
#else
            if LegacyDaemonInstaller.isInstalled {
                try LegacyDaemonInstaller.install()
            } else {
                try await registerSystemDaemon()
            }
#endif
            daemonError = nil
        } catch {
            daemonError = String(format: L("后台服务安装失败：%@"), error.localizedDescription)
            presentInstallFailure(error)
        }
        refresh()
    }

    func beginUninstall() {
        guard canUninstallDaemon, !uninstallBusy, !installBusy else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("删除后台服务")
        alert.informativeText = L("service.uninstall.explanation")
        alert.addButton(withTitle: L("删除"))
        alert.addButton(withTitle: L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        uninstallBusy = true
        Task { await uninstallDaemon() }
    }

    @MainActor private func uninstallDaemon() async {
        defer {
            uninstallBusy = false
            refresh()
        }

        invalidateConnection()
        do {
            let service = SMAppService.daemon(
                plistName: "com.nvksie.chargelmt.daemon.plist"
            )
            if service.status == .enabled || service.status == .requiresApproval {
                try await service.unregister()
            }
            try LegacyDaemonInstaller.uninstall()
            daemonConnected = false
            daemonError = nil
        } catch {
            daemonError = String(format: L("后台服务删除失败：%@"), error.localizedDescription)
            presentInstallFailure(error, title: L("后台服务删除失败"))
        }
    }

    private func registerSystemDaemon() async throws {
        let service = SMAppService.daemon(
            plistName: "com.nvksie.chargelmt.daemon.plist"
        )
        if service.status == .enabled || service.status == .requiresApproval {
            try? await service.unregister()
        }
        try service.register()
        daemonStatus = service.status

        if service.status == .requiresApproval {
            openLoginItemsSettings()
            daemonError = L("请在系统设置的“登录项与扩展”中允许 ChargeLmt")
        }
    }

    private func presentInstallFailure(
        _ error: Error,
        title: String = L("后台服务安装失败")
    ) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L("好"))
        alert.runModal()
    }

    private func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    func openServiceApprovalSettings() {
        openLoginItemsSettings()
    }

    private func invalidateConnection() {
        connection?.invalidate()
        connection = nil
        daemonConnected = false
    }

    func clampLimits() {
        minCharge = min(max(minCharge, ChargeLimits.minimum), ChargeLimits.maximum - 1)
        maxCharge = min(max(maxCharge, minCharge + 1), ChargeLimits.maximum)
    }

    private var remoteProxy: ChargeDaemonProtocol {
        if let connection {
            return remoteProxy(for: connection)
        }

        let newConnection = NSXPCConnection(
            machServiceName: DaemonMachService.name,
            options: .privileged
        )
        newConnection.remoteObjectInterface = NSXPCInterface(
            with: ChargeDaemonProtocol.self
        )
        newConnection.resume()
        connection = newConnection
        return remoteProxy(for: newConnection)
    }

    private func remoteProxy(
        for connection: NSXPCConnection
    ) -> ChargeDaemonProtocol {
        return connection.remoteObjectProxyWithErrorHandler { [weak self, weak connection] error in
            RunLoop.main.perform {
                self?.daemonConnected = false
                self?.daemonError = String(
                    format: L("无法连接后台服务：%@"),
                    error.localizedDescription
                )
                guard let self, let connection,
                      self.connection === connection else { return }
                connection.invalidate()
                self.connection = nil
            }
        } as! ChargeDaemonProtocol
    }
}
