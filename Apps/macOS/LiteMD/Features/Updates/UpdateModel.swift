import AppKit
import LiteMDUpdates
import Observation
import Security

/// 应用内更新：检查更新源 → 下载并校验 Ed25519 签名 → 解压并校验代码签名 → 退出后替换应用并重新打开。
///
/// 更新源地址与公钥写在 Info.plist（发布脚本注入）；未配置时不检查更新。
@MainActor
@Observable
final class UpdateModel {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateItem)
        case installing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    var checksAutomatically: Bool {
        didSet { UserDefaults.standard.set(checksAutomatically, forKey: Self.automaticKey) }
    }

    /// 已准备好的新版本；退出获准后由 AppDelegate 替换。
    @ObservationIgnored private(set) var preparedApplication: URL?

    private static let automaticKey = "updates.automaticallyCheck"
    private static let lastCheckKey = "updates.lastCheck"

    let feedURL: URL?
    let publicKey: String

    init(bundle: Bundle = .main) {
        let feed = (bundle.object(forInfoDictionaryKey: "LiteMDUpdateFeedURL") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        feedURL = feed.isEmpty ? nil : URL(string: feed)
        publicKey = (bundle.object(forInfoDictionaryKey: "LiteMDUpdatePublicKey") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        checksAutomatically = UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool ?? true
    }

    var isConfigured: Bool { feedURL != nil && !publicKey.isEmpty }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var currentBuild: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    private var checker: UpdateChecker? {
        guard let feedURL, !publicKey.isEmpty else { return nil }
        return UpdateChecker(feedURL: feedURL, publicKey: publicKey)
    }

    // MARK: Check

    /// 启动时：开启自动检查且距上次检查超过一天时静默检查，发现新版本才提示。
    func checkOnLaunchIfNeeded() {
        guard isConfigured, checksAutomatically else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 60 * 60 else { return }
        Task {
            try? await Task.sleep(for: .seconds(5))
            await check(userInitiated: false)
        }
    }

    func check(userInitiated: Bool) async {
        guard let checker else {
            if userInitiated {
                SystemIntegration.runAlert(
                    title: String(localized: "Updates are not available for this build."),
                    message: String(localized: "This copy of LiteMD was not built with an update source."),
                    buttons: [String(localized: "OK")],
                    style: .informational
                )
            }
            return
        }
        guard phase != .checking, phase != .installing else { return }
        phase = .checking
        do throws(UpdateError) {
            let item = try await checker.availableUpdate(
                currentVersion: Self.currentVersion,
                currentBuild: Self.currentBuild,
                systemVersion: ProcessInfo.processInfo.operatingSystemVersion
            )
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            if let item {
                phase = .available(item)
                // 自动检查不弹出模态提示（正在输入时按回车可能误点安装），只在状态栏显示入口。
                if userInitiated { promptToInstall(item) }
            } else {
                phase = .upToDate
                if userInitiated {
                    SystemIntegration.runAlert(
                        title: String(localized: "LiteMD is up to date."),
                        message: String(localized: "Version \(Self.currentVersion) is the latest version."),
                        buttons: [String(localized: "OK")],
                        style: .informational
                    )
                }
            }
        } catch {
            phase = .failed(Self.message(for: error))
            if userInitiated {
                SystemIntegration.runAlert(
                    title: String(localized: "Could not check for updates."),
                    message: Self.message(for: error),
                    buttons: [String(localized: "OK")]
                )
            }
        }
    }

    func promptToInstall(_ item: UpdateItem) {
        let notes = item.notes(for: Bundle.main.preferredLocalizations + Locale.preferredLanguages) ?? ""
        let choice = SystemIntegration.runAlert(
            title: String(localized: "LiteMD \(item.version) is available."),
            message: String(localized: "You have version \(Self.currentVersion). LiteMD will save your documents, install the update and reopen."),
            buttons: [String(localized: "Later"), String(localized: "Install and Relaunch")],
            style: .informational,
            details: notes
        )
        guard choice == 1 else { return }
        Task { await install(item) }
    }

    // MARK: Install

    func install(_ item: UpdateItem) async {
        guard let checker else { return }
        phase = .installing
        do {
            let data = try await checker.download(item)
            let application = try await Task.detached(priority: .userInitiated) {
                try Self.prepare(package: data, expectedVersion: item.version)
            }.value
            preparedApplication = application
            AppModel.shared.relaunch()
        } catch let error as UpdateError {
            fail(Self.message(for: error))
        } catch let error as InstallError {
            fail(error.message)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        SystemIntegration.runAlert(
            title: String(localized: "The update could not be installed."),
            message: message,
            buttons: [String(localized: "OK")]
        )
    }

    struct InstallError: Error {
        let message: String
    }

    /// 解压安装包并校验：包含同一 Bundle ID、版本号一致、代码签名有效，且与当前应用属于同一开发者团队。
    nonisolated static func prepare(package: Data, expectedVersion: String) throws -> URL {
        let current = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            throw InstallError(message: String(localized: "LiteMD cannot replace itself in “\(current.deletingLastPathComponent().path)”. Move LiteMD to the Applications folder and try again."))
        }

        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("LiteMD-Update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let archive = workspace.appendingPathComponent("update.zip")
        try package.write(to: archive)

        let extracted = workspace.appendingPathComponent("extracted", isDirectory: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, extracted.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw InstallError(message: String(localized: "The update package could not be opened.")) }

        guard let application = try FileManager.default.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }),
              let bundle = Bundle(url: application),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == expectedVersion else {
            throw InstallError(message: String(localized: "The update package does not contain the expected version of LiteMD."))
        }
        guard codeSignatureIsValid(application), teamIdentifier(of: application) == teamIdentifier(of: current) else {
            throw InstallError(message: String(localized: "The code signature of the update could not be verified."))
        }
        return application
    }

    nonisolated private static func staticCode(_ url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess else { return nil }
        return code
    }

    nonisolated static func codeSignatureIsValid(_ url: URL) -> Bool {
        guard let code = staticCode(url) else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), nil) == errSecSuccess
    }

    nonisolated static func teamIdentifier(of url: URL) -> String? {
        guard let code = staticCode(url) else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// 当前进程退出后替换应用包并重新打开。旧版本移到临时目录，替换失败时放回原处。
    func scheduleInstallation() {
        guard let preparedApplication else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        let target = Bundle.main.bundleURL.path
        let backup = FileManager.default.temporaryDirectory.appendingPathComponent("LiteMD-Previous-\(UUID().uuidString).app").path
        let script = """
        while kill -0 "$0" 2>/dev/null; do sleep 0.2; done
        if mv "$1" "$3"; then
          if mv "$2" "$1"; then
            /usr/bin/open "$1"
          else
            mv "$3" "$1"
            /usr/bin/open "$1"
          fi
        fi
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, String(pid), target, preparedApplication.path, backup]
        try? process.run()
    }

    static func message(for error: UpdateError) -> String {
        switch error {
        case .notConfigured:
            String(localized: "This copy of LiteMD was not built with an update source.")
        case .invalidFeed:
            String(localized: "The update information could not be read.")
        case .network(let message):
            String(localized: "Could not connect to the update server. \(message)")
        case .lengthMismatch:
            String(localized: "The downloaded update is incomplete.")
        case .invalidSignature:
            String(localized: "The update is not signed by the LiteMD developer and was not installed.")
        case .unsupportedSystem(let version):
            String(localized: "The new version requires macOS \(version) or later.")
        }
    }
}
