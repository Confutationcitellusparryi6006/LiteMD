import Foundation
import LiteMDBackup
import LiteMDDomain
import Observation

/// S3 备份：把当前打开的文件夹单向备份到桶中。
///
/// - 只上传新增与修改的文件，从不修改本地文件；
/// - 自动备份在变更平静约一分钟后执行，持续编辑时最迟五分钟执行一次；
/// - Secret Access Key 保存在钥匙串中。
@MainActor
@Observable
final class BackupModel {
    enum Phase: Equatable {
        case idle
        case running(BackupProgress)
        case failed(String)
    }

    enum ConnectionStatus: Equatable {
        case unknown
        case testing
        case connected
        case failed(String)
    }

    enum Trigger {
        case manual
        case automatic
    }

    private(set) var phase: Phase = .idle
    private(set) var connectionStatus: ConnectionStatus = .unknown
    private(set) var hasSecret: Bool
    /// 按文件夹路径保存的最近一次备份结果。
    private(set) var reports: [String: BackupReport]

    @ObservationIgnored var workspaceRoot: () -> URL? = { nil }
    @ObservationIgnored var ignoreRules: () -> WorkspaceIgnoreRules = { WorkspaceIgnoreRules() }
    /// 需要用户补全设置时打开“备份”设置页。
    @ObservationIgnored var openSettings: () -> Void = {}

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let keychain = KeychainStore(service: "app.litemd.LiteMD.backup")
    @ObservationIgnored private let manifestStore: FileBackupManifestStore
    @ObservationIgnored private let reportsURL: URL
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var scheduledTask: Task<Void, Never>?
    @ObservationIgnored private var firstPendingChange: Date?
    @ObservationIgnored private var needsAnotherRun = false
    @ObservationIgnored private var pendingSecretWrite: Task<Void, Never>?

    private static let secretAccount = "s3-secret-access-key"
    private static let quietPeriod: Duration = .seconds(60)
    private static let maximumDelay: TimeInterval = 300

    #if DEBUG
    /// 仅用于本地调试：通过环境变量提供 Secret，不读写钥匙串。
    private static let debugSecret = ProcessInfo.processInfo.environment["LITEMD_DEBUG_S3_SECRET"]
    #endif

    init(settings: AppSettings, directory: URL) {
        self.settings = settings
        manifestStore = FileBackupManifestStore(directory: directory.appendingPathComponent("Manifests", isDirectory: true))
        reportsURL = directory.appendingPathComponent("reports.json")
        reports = (try? Data(contentsOf: reportsURL)).flatMap { try? JSONDecoder().decode([String: BackupReport].self, from: $0) } ?? [:]
        #if DEBUG
        hasSecret = Self.debugSecret != nil || keychain.contains(account: Self.secretAccount)
        #else
        hasSecret = keychain.contains(account: Self.secretAccount)
        #endif
    }

    // MARK: State

    var configuration: S3Configuration { settings.backupConfiguration }

    var isConfigured: Bool { configuration.isComplete && hasSecret }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    func lastReport(for workspace: URL?) -> BackupReport? {
        workspace.flatMap { reports[$0.standardizedFileURL.path] }
    }

    /// 桶内位置，例如 `notes-backup/LiteMD/Notes-1a2b3c/`。
    func remoteLocation(for workspace: URL) -> String {
        "\(configuration.bucket)/\(BackupEngine.remoteFolder(for: workspace, configuration: configuration))"
    }

    // MARK: Secret

    /// 读取钥匙串可能弹出系统授权框，因此在主线程之外执行，界面不会被卡住。
    func loadSecret() async -> String {
        #if DEBUG
        if let secret = Self.debugSecret { return secret }
        #endif
        let keychain = keychain
        let account = Self.secretAccount
        let pendingWrite = pendingSecretWrite
        return await Task.detached {
            await pendingWrite?.value
            return keychain.read(account: account) ?? ""
        }.value
    }

    func saveSecret(_ secret: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        hasSecret = !trimmed.isEmpty
        connectionStatus = .unknown
        let keychain = keychain
        let account = Self.secretAccount
        let previous = pendingSecretWrite
        pendingSecretWrite = Task.detached {
            await previous?.value
            keychain.write(trimmed, account: account)
        }
    }

    func configurationDidChange() {
        connectionStatus = .unknown
    }

    // MARK: Actions

    func testConnection() {
        guard configuration.isComplete else {
            connectionStatus = .failed(String(localized: "Fill in the bucket, region and access key first."))
            return
        }
        connectionStatus = .testing
        let configuration = configuration
        Task {
            let secret = await loadSecret()
            guard !secret.isEmpty else {
                connectionStatus = .failed(Self.message(for: .invalidConfiguration("secret")))
                return
            }
            do throws(S3Error) {
                try await S3Client(configuration: configuration, secretAccessKey: secret).checkAccess()
                connectionStatus = .connected
            } catch {
                connectionStatus = .failed(Self.message(for: error))
            }
        }
    }

    func backUpNow() {
        run(.manual)
    }

    func cancel() {
        runTask?.cancel()
    }

    /// 文件夹中有文件被保存或修改。
    func noteLocalChange(at url: URL) {
        guard settings.backupAutomatic, isConfigured, let root = workspaceRoot() else { return }
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return }

        let now = Date()
        let first = firstPendingChange ?? now
        firstPendingChange = first
        let remaining = max(0, Self.maximumDelay - now.timeIntervalSince(first))
        schedule(after: min(Self.quietPeriod, .seconds(remaining)))
    }

    /// 打开文件夹后补做一次备份（覆盖 LiteMD 未运行期间的修改）。
    func workspaceDidOpen() {
        guard settings.backupAutomatic, isConfigured else { return }
        schedule(after: .seconds(10))
    }

    func workspaceDidClose() {
        scheduledTask?.cancel()
        firstPendingChange = nil
    }

    private func schedule(after delay: Duration) {
        scheduledTask?.cancel()
        scheduledTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.run(.automatic)
        }
    }

    private func run(_ trigger: Trigger) {
        guard let workspace = workspaceRoot() else {
            if trigger == .manual {
                SystemIntegration.runAlert(
                    title: String(localized: "Open a folder to back up."),
                    message: String(localized: "S3 backup uploads the files in the folder that is open in LiteMD."),
                    buttons: [String(localized: "OK")],
                    style: .informational
                )
            }
            return
        }
        guard isConfigured else {
            if trigger == .manual { openSettings() }
            return
        }
        guard !isRunning else {
            needsAnotherRun = true
            return
        }

        scheduledTask?.cancel()
        firstPendingChange = nil
        needsAnotherRun = false
        phase = .running(BackupProgress(completed: 0, total: 0, currentPath: nil))

        let configuration = configuration
        let manifestStore = manifestStore
        let options = BackupOptions(mirrorDeletions: settings.backupMirrorDeletions, ignoreRules: ignoreRules())
        let key = workspace.standardizedFileURL.path

        runTask = Task { [weak self] in
            guard let secret = await self?.loadSecret() else { return }
            guard !secret.isEmpty else {
                self?.finish(.failure(.invalidConfiguration("secret")), key: key, trigger: trigger, cancelled: false)
                return
            }
            let engine = BackupEngine(
                client: S3Client(configuration: configuration, secretAccessKey: secret),
                manifestStore: manifestStore
            )
            let result: Result<BackupReport, S3Error>
            do throws(S3Error) {
                result = .success(try await engine.run(workspace: workspace, options: options) { progress in
                    Task { @MainActor in self?.updateProgress(progress) }
                })
            } catch {
                result = .failure(error)
            }
            self?.finish(result, key: key, trigger: trigger, cancelled: Task.isCancelled)
        }
    }

    private func updateProgress(_ progress: BackupProgress) {
        guard case .running(let current) = phase, progress.completed >= current.completed else { return }
        phase = .running(progress)
    }

    private func finish(_ result: Result<BackupReport, S3Error>, key: String, trigger: Trigger, cancelled: Bool) {
        runTask = nil
        defer {
            if needsAnotherRun, !cancelled {
                needsAnotherRun = false
                schedule(after: .seconds(5))
            }
        }
        guard !cancelled else {
            phase = .idle
            return
        }
        switch result {
        case .success(let report):
            reports[key] = report
            persistReports()
            if report.succeeded {
                phase = .idle
            } else {
                phase = .failed(String(localized: "\(report.failures.count) files could not be backed up."))
            }
        case .failure(let error):
            let message = Self.message(for: error)
            phase = .failed(message)
            if trigger == .manual {
                SystemIntegration.runAlert(
                    title: String(localized: "Backup failed."),
                    message: message,
                    buttons: [String(localized: "OK")],
                    details: BackupEngine.describe(error)
                )
            }
        }
    }

    private func persistReports() {
        let url = reportsURL
        guard let data = try? JSONEncoder().encode(reports) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Restore

    struct OperationError: Error {
        let message: String
    }

    /// Workspace 在桶内的前缀。
    func remoteFolder(for workspace: URL) -> String {
        BackupEngine.remoteFolder(for: workspace, configuration: configuration)
    }

    func remoteBackupFolders() async -> Result<[RemoteBackupFolder], OperationError> {
        guard configuration.isComplete else {
            return .failure(OperationError(message: String(localized: "Set up S3 backup in Settings first.")))
        }
        let secret = await loadSecret()
        guard !secret.isEmpty else { return .failure(OperationError(message: Self.message(for: .invalidConfiguration("secret")))) }
        do throws(S3Error) {
            return .success(try await RestoreEngine(client: S3Client(configuration: configuration, secretAccessKey: secret)).backupFolders())
        } catch {
            return .failure(OperationError(message: Self.message(for: error)))
        }
    }

    func restore(
        _ folder: RemoteBackupFolder,
        to destination: URL,
        progress: @escaping @Sendable (BackupProgress) -> Void
    ) async -> Result<RestoreReport, OperationError> {
        let secret = await loadSecret()
        guard !secret.isEmpty else { return .failure(OperationError(message: Self.message(for: .invalidConfiguration("secret")))) }
        let engine = RestoreEngine(client: S3Client(configuration: configuration, secretAccessKey: secret))
        do throws(S3Error) {
            return .success(try await engine.restore(folder: folder, to: destination, progress: progress))
        } catch {
            return .failure(OperationError(message: Self.message(for: error)))
        }
    }

    // MARK: Messages

    static func message(for error: S3Error) -> String {
        switch error {
        case .invalidConfiguration("insecureEndpoint"):
            return String(localized: "Use an HTTPS endpoint. Plain HTTP is only allowed for servers on this Mac.")
        case .invalidConfiguration("secret"):
            return String(localized: "Enter the secret access key.")
        case .invalidConfiguration("bucket"):
            return String(localized: "Enter a bucket name.")
        case .invalidConfiguration:
            return String(localized: "The endpoint address is not valid.")
        case .http(let status, let code, _):
            switch code {
            case "SignatureDoesNotMatch":
                return String(localized: "The secret access key is incorrect.")
            case "InvalidAccessKeyId":
                return String(localized: "The access key ID does not exist.")
            case "NoSuchBucket":
                return String(localized: "The bucket does not exist.")
            case "AuthorizationHeaderMalformed", "PermanentRedirect", "IllegalLocationConstraintException":
                return String(localized: "The region does not match the bucket. Check the region setting.")
            case "AccessDenied":
                return String(localized: "Access denied. Make sure the key can list, upload and delete objects in this bucket.")
            default:
                if status == 301 || status == 307 {
                    return String(localized: "The region does not match the bucket. Check the region setting.")
                }
                if status == 403 {
                    return String(localized: "Access denied. Make sure the key can list, upload and delete objects in this bucket.")
                }
                if status == 404 {
                    return String(localized: "The bucket does not exist.")
                }
                return String(localized: "The server returned an error (HTTP \(status)).")
            }
        case .transport(let message):
            return String(localized: "Could not connect to the server. \(message)")
        case .invalidResponse:
            return String(localized: "The server returned an unexpected response.")
        }
    }
}
