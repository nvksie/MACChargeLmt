import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("充电阈值") {
                HStack {
                    Text("上限")
                    Slider(
                        value: Binding(
                            get: { Double(model.maxCharge) },
                            set: { model.setLocalMaxCharge(Int($0.rounded())) }
                        ),
                        in: 51...100,
                        step: 1
                    )
                    Text("\(model.maxCharge)%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }

                HStack {
                    Text("下限")
                    Slider(
                        value: Binding(
                            get: { Double(model.minCharge) },
                            set: { model.setLocalMinCharge(Int($0.rounded())) }
                        ),
                        in: 50...99,
                        step: 1
                    )
                    Text("\(model.minCharge)%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }

                Text("达到上限停止充电，降到下限恢复充电。下限范围 50%-99%。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("应用阈值") {
                    model.applyLimits()
                }
                .disabled(!model.daemonConnected)

                if model.hasPendingLimitChanges {
                    Text("阈值已调整，尚未应用到后台服务。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section("一次性操作") {
                HStack {
                    Button("充满一次") { model.requestMode(.chargeFull) }
                        .disabled(!model.daemonConnected || model.mode == .chargeFull)
                    Button("放电到上限") { model.requestMode(.dischargeToLimit) }
                        .disabled(!model.daemonConnected || !model.supportsDischarge || model.mode == .dischargeToLimit)
                    Button("取消") { model.requestMode(.normal) }
                        .disabled(model.mode == .normal)
                }
                Text("充满一次用于电池校准；放电到上限会临时关闭适配器输出。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("启动与服务") {
                NativeLoginItemToggle(model: model)
                if model.loginItemBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在更新自启动设置...").font(.footnote).foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text(daemonStatusText)
                    Spacer()
                    NativeServiceButton(model: model, action: .install)
                    NativeServiceButton(model: model, action: .uninstall)
                }

                Text("删除 ChargeLmt.app 前请先删除后台服务；macOS 不提供 App 删除回调。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let error = model.daemonError, !error.isEmpty {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
                if let stage = model.installStage {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(stage).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !model.daemonConnected && model.legacyDaemonInstalled {
                    Text("本地 daemon 已安装，但 XPC 尚未连接。").font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("状态") {
                LabeledContent("当前电量", value: "\(model.percent)%")
                LabeledContent(
                    "充电状态",
                    value: model.charging ? L("充电中") : L("未充电")
                )
                LabeledContent(
                    "电源适配器",
                    value: model.adapterConnected ? L("已连接") : L("未连接")
                )
                LabeledContent("当前模式", value: modeText)
                LabeledContent(
                    "控制后端",
                    value: model.daemonConnected ? model.backend : L("未连接")
                )
                LabeledContent(
                    "强制放电",
                    value: model.supportsDischarge ? L("支持") : L("不支持")
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
    }

    private var daemonStatusText: String {
        if model.daemonConnected || model.legacyDaemonInstalled {
            return model.daemonConnected
                ? L("后台服务已启用")
                : L("本地后台服务已安装，等待连接")
        }
        switch model.daemonStatus {
        case .enabled: return L("后台服务已启用")
        case .requiresApproval: return L("需要在系统设置中批准")
        default: return L("后台服务未安装")
        }
    }

    private var modeText: String {
        switch model.mode {
        case .normal: return L("阈值控制")
        case .chargeFull: return L("充满一次")
        case .dischargeToLimit: return L("放电到上限")
        }
    }
}

private struct NativeLoginItemToggle: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: L("登录时自动启动"),
            target: context.coordinator,
            action: #selector(Coordinator.toggle)
        )
        button.setButtonType(.switch)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.state = model.loginItemEnabled ? .on : .off
        button.isEnabled = !model.loginItemBusy && !model.installBusy
    }

    final class Coordinator: NSObject {
        private let model: AppModel

        init(model: AppModel) {
            self.model = model
        }

        @MainActor @objc func toggle(_ sender: NSButton) {
            model.beginSetLoginItem(sender.state == .on)
        }
    }
}

private enum ServiceAction {
    case install
    case uninstall
}

private struct NativeServiceButton: NSViewRepresentable {
    @ObservedObject var model: AppModel
    let action: ServiceAction

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: title,
            target: context.coordinator,
            action: #selector(Coordinator.performAction)
        )
        button.bezelStyle = .rounded
        button.controlSize = .regular
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title
        button.isEnabled = isEnabled
    }

    private var title: String {
        switch action {
        case .install:
        if model.daemonStatus == .requiresApproval {
            return L("打开系统设置")
        }
        if model.daemonUpdateAvailable {
            return L("更新后台服务")
        }
        return model.daemonStatus == .enabled || model.legacyDaemonInstalled
            ? L("重新安装") : L("安装")
        case .uninstall:
            return L("删除后台服务")
        }
    }

    private var isEnabled: Bool {
        switch action {
        case .install:
            return !model.installBusy && !model.uninstallBusy
        case .uninstall:
            return model.canUninstallDaemon
                && !model.installBusy
                && !model.uninstallBusy
        }
    }

    final class Coordinator: NSObject {
        private let model: AppModel
        private let action: ServiceAction

        init(model: AppModel, action: ServiceAction) {
            self.model = model
            self.action = action
        }

        @MainActor @objc func performAction() {
            switch action {
            case .install:
                if model.daemonStatus == .requiresApproval {
                    model.openServiceApprovalSettings()
                } else {
                    model.beginInstall()
                }
            case .uninstall:
                model.beginUninstall()
            }
        }
    }
}
