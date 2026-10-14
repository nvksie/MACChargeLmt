import AppKit
import Sparkle
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var updaterController: SPUStandardUpdaterController?
    private var didCheckAutoInstall = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        setupStatusItem()
        model.refresh()
        Timer.scheduledTimer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(autoInstallIfNeeded),
            userInfo: nil,
            repeats: false
        )
    }

    func showSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("ChargeLmt 设置")
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    func showAbout() {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0"
        let alert = NSAlert()
        alert.messageText = "ChargeLmt \(version)"
        alert.informativeText = L("about.message")
        alert.addButton(withTitle: L("好"))
        alert.addButton(withTitle: L("打开项目主页"))
        if alert.runModal() == .alertSecondButtonReturn,
           let url = URL(string: "https://github.com/nvksie/MACChargeLmt") {
            NSWorkspace.shared.open(url)
        }
    }

    func checkForUpdates() {
        updaterController?.updater.checkForUpdates()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        if let button = item.button {
            let icon = NSImage(named: "MenuIcon")
            icon?.size = NSSize(width: 18, height: 18)
            icon?.isTemplate = true
            button.image = icon
            button.imageScaling = .scaleProportionallyDown
        }

        // 使用系统原生托管的 NSStatusItem.menu
        // 1. 系统底层自动支持跨屏幕穿透点击（Click-Through），无论屏幕是否失焦，单次点击直接弹出菜单；
        // 2. isTemplate = true 时，图标跟随所在屏幕的输入焦点自动完成 Active/Inactive 亮暗平滑切换。
        let menu = buildMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let status = NSMenuItem(
            title: model.statusText,
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let install = NSMenuItem(
            title: L("安装后台服务"),
            action: #selector(installDaemonAction),
            keyEquivalent: ""
        )
        install.tag = MenuItemTags.installDaemon
        install.isHidden = !model.shouldShowInstallMenuItem
        install.isEnabled = !model.installBusy
        menu.addItem(install)
        let installSeparator = NSMenuItem.separator()
        installSeparator.tag = MenuItemTags.installDaemonSeparator
        installSeparator.isHidden = install.isHidden
        menu.addItem(installSeparator)

        menu.addItem(withTitle: L("设置"), action: #selector(showSettingsAction), keyEquivalent: ",")
        menu.addItem(withTitle: L("检查更新"), action: #selector(checkUpdatesAction), keyEquivalent: "u")
        menu.addItem(withTitle: L("关于"), action: #selector(showAboutAction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("退出"), action: #selector(quitAction), keyEquivalent: "q")

        menu.items.forEach { $0.target = self }
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let first = menu.items.first else { return }
        first.title = model.statusText
        if let install = menu.item(withTag: MenuItemTags.installDaemon) {
            install.title = model.daemonUpdateAvailable
                ? L("更新后台服务") : L("安装后台服务")
            install.isHidden = !model.shouldShowInstallMenuItem
            install.isEnabled = !model.installBusy
            menu.item(withTag: MenuItemTags.installDaemonSeparator)?.isHidden = install.isHidden
        }
    }

    @objc private func showSettingsAction() { showSettings() }
    @objc private func installDaemonAction() { model.beginInstall() }
    @objc private func autoInstallIfNeeded() {
        guard !didCheckAutoInstall else { return }
        didCheckAutoInstall = true
        guard model.shouldShowInstallMenuItem, !model.installBusy else { return }
        model.beginInstall()
    }
    @objc private func checkUpdatesAction() { checkForUpdates() }
    @objc private func showAboutAction() { showAbout() }
    @objc private func quitAction() { NSApp.terminate(nil) }

    private enum MenuItemTags {
        static let installDaemon = 1_001
        static let installDaemonSeparator = 1_002
    }
}

