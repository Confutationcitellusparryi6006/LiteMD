import LiteMDBackup
import SwiftUI

/// 设置 → 备份：S3 兼容存储的地址、凭据与备份选项。
struct BackupSettings: View {
    @Environment(AppModel.self) private var model
    @State private var secret = ""
    @State private var savedSecret = ""
    @State private var didLoadSecret = false
    @State private var isRestorePresented = false

    var body: some View {
        @Bindable var settings = model.settings
        let backup = model.backup

        Form {
            Section {
                Picker("Service", selection: $settings.backupProvider) {
                    ForEach(S3Provider.allCases, id: \.self) { provider in
                        Text(LocalizedStringKey(provider.displayName)).tag(provider)
                    }
                }
                if settings.backupProvider.requiresEndpoint {
                    TextField("Endpoint", text: $settings.backupEndpoint, prompt: Text(verbatim: settings.backupProvider.endpointPlaceholder))
                }
                TextField("Region", text: $settings.backupRegion, prompt: Text(verbatim: settings.backupProvider.regionPlaceholder))
                TextField("Bucket", text: $settings.backupBucket, prompt: Text(verbatim: "my-notes-backup"))
                TextField("Folder in bucket", text: $settings.backupPrefix, prompt: Text(verbatim: "LiteMD"))
                if settings.backupProvider == .other {
                    Toggle("Use path-style addressing", isOn: $settings.backupPathStyle)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text(providerHint(settings.backupProvider))
            }

            Section {
                TextField("Access key ID", text: $settings.backupAccessKeyID)
                SecureField("Secret access key", text: $secret)
            } header: {
                Text("Credentials")
            } footer: {
                Text("The secret access key is stored in your Keychain. Use a key that can only access this bucket.")
            }

            Section {
                Toggle("Back up automatically", isOn: $settings.backupAutomatic)
                Toggle("Delete remote copies of deleted files", isOn: $settings.backupMirrorDeletions)
            } header: {
                Text("Backup")
            } footer: {
                Text("Backups are one-way: LiteMD uploads new and changed files from the open folder and never changes files on this Mac. Files you delete stay in the bucket unless you turn on the option above.")
            }

            Section {
                HStack(spacing: Space.s2) {
                    Button("Test Connection") {
                        commitSecret()
                        backup.testConnection()
                    }
                    .disabled(backup.connectionStatus == .testing)
                    ConnectionStatusLabel(status: backup.connectionStatus)
                    Spacer()
                    if backup.isRunning {
                        Button("Stop") { backup.cancel() }
                    } else {
                        Button("Back Up Now") {
                            commitSecret()
                            backup.backUpNow()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!backup.isConfigured || model.workspace.rootURL == nil)
                    }
                }
                BackupStatusDetails()
                HStack {
                    Spacer()
                    Button("Restore from Backup…") { isRestorePresented = true }
                        .disabled(!backup.isConfigured)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isRestorePresented) {
            RestoreBackupView()
                .environment(model)
        }
        .task {
            guard !didLoadSecret else { return }
            // 只有已经保存过时才读取钥匙串，避免无意义的授权提示。
            if backup.hasSecret {
                let stored = await backup.loadSecret()
                savedSecret = stored
                if secret.isEmpty { secret = stored }
            }
            didLoadSecret = true
        }
        .onDisappear(perform: commitSecret)
        .onChange(of: secret) { commitSecret() }
        .onChange(of: settings.backupConfiguration) { backup.configurationDidChange() }
        .onChange(of: settings.backupProvider) { oldValue, newValue in
            if settings.backupRegion.isEmpty || settings.backupRegion == oldValue.defaultRegion {
                settings.backupRegion = newValue.defaultRegion
            }
        }
    }

    private func commitSecret() {
        guard didLoadSecret, secret != savedSecret else { return }
        savedSecret = secret
        model.backup.saveSecret(secret)
    }

    private func providerHint(_ provider: S3Provider) -> LocalizedStringKey {
        switch provider {
        case .aws:
            "Uses the regional endpoint of the bucket, for example s3.us-west-2.amazonaws.com."
        case .cloudflareR2:
            "Find the S3 API endpoint and create an API token under R2 → Manage R2 API Tokens. The region is always “auto”."
        case .minio:
            "Plain HTTP is only allowed for a server running on this Mac. Use HTTPS for servers on your network."
        case .other:
            "Works with Aliyun OSS, Tencent COS, Backblaze B2, Wasabi and other services that support the S3 API with Signature Version 4."
        }
    }
}

private struct ConnectionStatusLabel: View {
    let status: BackupModel.ConnectionStatus

    var body: some View {
        switch status {
        case .unknown:
            EmptyView()
        case .testing:
            HStack(spacing: Space.s1) {
                ProgressView().controlSize(.small)
                Text("Testing…").foregroundStyle(Color.textSecondary)
            }
            .font(.system(size: TextSize.xs))
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.system(size: TextSize.xs))
                .foregroundStyle(Color.statusSuccess)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: TextSize.xs))
                .foregroundStyle(Color.statusError)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }
}

/// 当前文件夹的备份状态：进度、上次结果、桶内位置。设置页与侧栏弹出框共用。
struct BackupStatusDetails: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let backup = model.backup
        let root = model.workspace.rootURL

        VStack(alignment: .leading, spacing: Space.s2) {
            switch backup.phase {
            case .running(let progress):
                VStack(alignment: .leading, spacing: Space.s1) {
                    if progress.total > 0 {
                        ProgressView(value: progress.fraction)
                        Text("Uploading \(progress.completed) of \(progress.total)…")
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                        Text("Comparing files…")
                    }
                }
                .font(.system(size: TextSize.xs))
                .foregroundStyle(Color.textSecondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: TextSize.xs))
                    .foregroundStyle(Color.statusError)
                    .textSelection(.enabled)
            case .idle:
                EmptyView()
            }

            if let report = backup.lastReport(for: root) {
                row("Last backup") {
                    Text(report.finishedAt, format: .relative(presentation: .named))
                }
                row("Result") {
                    Text(summary(report))
                }
                if let failure = report.failures.first {
                    row("Failed") {
                        Text(verbatim: "\(failure.path): \(failure.message)")
                            .lineLimit(2)
                    }
                }
            } else if root != nil, !backup.isRunning {
                Text("This folder has not been backed up yet.")
                    .font(.system(size: TextSize.xs))
                    .foregroundStyle(Color.textSecondary)
            }

            if let root, backup.configuration.isComplete {
                row("Location") {
                    Text(verbatim: backup.remoteLocation(for: root))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            } else if root == nil {
                Text("Open a folder to back it up.")
                    .font(.system(size: TextSize.xs))
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ title: LocalizedStringKey, @ViewBuilder value: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Text(title)
                .foregroundStyle(Color.textSecondary)
                .frame(width: Space.s16 + Space.s4, alignment: .leading)
            value()
                .foregroundStyle(Color.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: TextSize.xs))
    }

    private func summary(_ report: BackupReport) -> String {
        var parts = [String(localized: "\(report.uploaded) uploaded"), String(localized: "\(report.unchanged) unchanged")]
        if report.deleted > 0 { parts.append(String(localized: "\(report.deleted) deleted")) }
        if report.skippedTooLarge > 0 { parts.append(String(localized: "\(report.skippedTooLarge) too large")) }
        if !report.failures.isEmpty { parts.append(String(localized: "\(report.failures.count) failed")) }
        return parts.joined(separator: " · ")
    }
}
