import Foundation
import ServiceManagement
import os

@MainActor
final class LoginItemManager {
    private let launchAgentLabel = "com.local.codex-usage-hud"
    private let logger = Logger(subsystem: "com.local.CodexUsageHUD", category: "login-item")

    func registerAtLogin() {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            logger.debug("Skipping login-item registration outside an app bundle")
            return
        }

        let service = SMAppService.mainApp
        switch service.status {
        case .enabled:
            removeLaunchAgentFallback()
            logger.debug("Login item is enabled")
        case .requiresApproval:
            logger.warning("Login item requires approval in System Settings")
            installLaunchAgentFallback()
        case .notRegistered:
            do {
                try service.register()
                logger.info("Registered to launch at login")
                if service.status == .enabled {
                    removeLaunchAgentFallback()
                } else {
                    installLaunchAgentFallback()
                }
            } catch {
                logger.error("Login-item registration failed: \(error.localizedDescription, privacy: .public)")
                installLaunchAgentFallback()
            }
        case .notFound:
            logger.error("Login item is unavailable for this app bundle")
            installLaunchAgentFallback()
        @unknown default:
            logger.error("Login item returned an unknown status")
            installLaunchAgentFallback()
        }
    }

    private var fallbackPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel).plist")
    }

    private func removeLaunchAgentFallback() {
        do {
            try FileManager.default.removeItem(at: fallbackPlistURL)
            logger.debug("Removed obsolete login agent fallback")
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            logger.error("Unable to remove obsolete login agent fallback: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func installLaunchAgentFallback() {
        let appPath = Bundle.main.bundlePath
        guard appPath.hasSuffix(".app") else {
            logger.error("Cannot install login agent without an app bundle path")
            return
        }

        let launchAgentsDirectory = fallbackPlistURL.deletingLastPathComponent()
        let plistURL = fallbackPlistURL
        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": ["/usr/bin/open", "-g", appPath],
            "RunAtLoad": true,
            "ProcessType": "Background"
        ]

        do {
            try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            logger.info("Installed user login agent fallback")
        } catch {
            logger.error("Login agent fallback failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
