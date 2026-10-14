import Foundation
import os
import AppKit
import CryptoKit

enum LegacyDaemonInstaller {
    private static let logger = Logger(
        subsystem: "com.nvksie.chargelmt.app",
        category: "LegacyDaemonInstaller"
    )
    private static let helperDestination = "/Library/PrivilegedHelperTools/com.nvksie.chargelmt.daemon"
    private static let plistDestination = "/Library/LaunchDaemons/com.nvksie.chargelmt.daemon.plist"

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: helperDestination)
    }

    static var needsUpdate: Bool {
        guard isInstalled,
              let bundledHash = try? sha256(at: bundledExecutableURL),
              let installedHash = try? sha256(at: URL(fileURLWithPath: helperDestination))
        else { return true }
        return bundledHash != installedHash
    }

    private static var bundledExecutableURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchServices/chargelmtd")
    }

    static func preflight() throws {
        _ = try makeInstallProcess()
    }

    static func install() throws {
        logger.notice("Install started")
        let (process, output) = try makeInstallProcess()
        NSApp.activate(ignoringOtherApps: true)
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(
                data: outputData,
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "LegacyDaemonInstaller",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: message.map {
                        String(format: L("管理员安装失败：%@"), $0)
                    } ?? L("管理员安装被取消或失败")
                ]
            )
        }
        logger.notice("Install complete")
    }

    static func uninstall() throws {
        guard isInstalled || FileManager.default.fileExists(atPath: plistDestination) else {
            return
        }

        let command = [
            "/bin/launchctl bootout system/com.nvksie.chargelmt.daemon 2>/dev/null || true",
            "/bin/rm -f \(shellQuoted(plistDestination)) \(shellQuoted(helperDestination))"
        ].joined(separator: "; ")

        let script = "do shell script \(appleScriptQuoted(command)) with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "LegacyDaemonInstaller",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: L("管理员卸载被取消或失败")]
            )
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func sha256(at url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func makeInstallProcess() throws -> (Process, Pipe) {
        guard FileManager.default.isExecutableFile(atPath: bundledExecutableURL.path) else {
            throw NSError(
                domain: "LegacyDaemonInstaller",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: String(
                        format: L("app 内缺少 chargelmtd：%@"),
                        bundledExecutableURL.path
                    )
                ]
            )
        }

        let plistURL = try legacyPlistURL()
        let command = [
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/usr/bin/install -m 0755 \(shellQuoted(bundledExecutableURL.path)) \(shellQuoted(helperDestination))",
            "/usr/bin/install -m 0644 \(shellQuoted(plistURL.path)) \(shellQuoted(plistDestination))",
            "/bin/launchctl kickstart -k system/com.nvksie.chargelmt.daemon 2>/dev/null || (/bin/launchctl bootout system/com.nvksie.chargelmt.daemon 2>/dev/null || true; /bin/sleep 0.3; /bin/launchctl bootstrap system \(shellQuoted(plistDestination)))"
        ].joined(separator: "; ")
        let script = "do shell script \(appleScriptQuoted(command)) with administrator privileges"

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = output
        process.standardError = output
        return (process, output)
    }

    private static func legacyPlistURL() throws -> URL {
        let candidates = Bundle.main.urls(
            forResourcesWithExtension: "plist",
            subdirectory: nil
        )?
            .filter { $0.lastPathComponent.hasSuffix("-legacy.plist") }
        ?? []

        guard let plistURL = candidates.first, candidates.count == 1 else {
            throw NSError(
                domain: "LegacyDaemonInstaller",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: candidates.isEmpty
                        ? L("app 内缺少 legacy daemon 安装文件")
                        : L("app 内存在多个 legacy daemon 安装文件")
                ]
            )
        }
        return plistURL
    }

    private static func appleScriptQuoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
