import LiteMDBackup
import SwiftUI

/// 从 S3 恢复：选择远端备份 → 选择本地位置 → 下载到新文件夹（不覆盖任何已有文件）。
struct RestoreBackupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case loading
        case failed(String)
        case choosing
        case restoring(BackupProgress)
        case finished(RestoreReport, URL)
    }

    @State private var phase: Phase = .loading
    @State private var folders: [RemoteBackupFolder] = []
    @State private var selection: RemoteBackupFolder?
    @State private var restoreTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text("Restore from Backup")
                    .font(.system(size: TextSize.lg, weight: .semibold))
                Text("Files are downloaded into a new folder. Existing files on this Mac are never overwritten.")
                    .font(.system(size: TextSize.xs))
                    .foregroundStyle(Color.textSecondary)
            }
            .padding(Space.s4)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: Space.s2) {
                Spacer()
                footerButtons
            }
            .padding(Space.s4)
        }
        .frame(width: Layout.quickOpenWidth, height: Layout.quickOpenHeight)
        .task { await loadFolders() }
        .onDisappear { restoreTask?.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView {
                Label("Could Not Load Backups", systemImage: "exclamationmark.icloud")
            } description: {
                Text(verbatim: message)
            } actions: {
                Button("Try Again") { Task { await loadFolders() } }
            }
        case .choosing:
            if folders.isEmpty {
                ContentUnavailableView("No Backups Found", systemImage: "icloud.slash", description: Text("Back up a folder first. Backups are stored under “\(model.backup.configuration.normalizedPrefix)” in the bucket."))
            } else {
                List(folders, selection: $selection) { folder in
                    HStack(spacing: Space.s3) {
                        Image(systemName: "folder")
                            .foregroundStyle(Color.textSecondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: folder.name)
                                .font(.system(size: TextSize.sm, weight: .semibold))
                                .foregroundStyle(Color.textPrimary)
                            Text(verbatim: "\(model.backup.configuration.bucket)/\(folder.prefix)")
                                .font(.system(size: TextSize.xs))
                                .foregroundStyle(Color.textTertiary)
                                .truncationMode(.middle)
                        }
                        .lineLimit(1)
                    }
                    .padding(.vertical, Space.s1)
                    .tag(folder)
                }
                .listStyle(.inset)
            }
        case .restoring(let progress):
            VStack(spacing: Space.s3) {
                if progress.total > 0 {
                    ProgressView(value: progress.fraction)
                    Text("Downloading \(progress.completed) of \(progress.total)…")
                } else {
                    ProgressView().progressViewStyle(.linear)
                    Text("Listing files…")
                }
            }
            .font(.system(size: TextSize.sm))
            .foregroundStyle(Color.textSecondary)
            .padding(Space.s8)
        case .finished(let report, let destination):
            VStack(spacing: Space.s3) {
                Image(systemName: report.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: TextSize.xxl))
                    .foregroundStyle(report.succeeded ? Color.statusSuccess : Color.statusWarning)
                Text("\(report.restored) files restored")
                    .font(.system(size: TextSize.base, weight: .semibold))
                if report.skippedExisting > 0 {
                    Text("\(report.skippedExisting) files already existed and were kept.")
                        .font(.system(size: TextSize.sm))
                        .foregroundStyle(Color.textSecondary)
                }
                if let failure = report.failures.first {
                    Text("\(report.failures.count) files could not be restored.")
                        .font(.system(size: TextSize.sm))
                        .foregroundStyle(Color.statusError)
                    Text(verbatim: "\(failure.path): \(failure.message)")
                        .font(.system(size: TextSize.xs))
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(2)
                }
                Text(verbatim: (destination.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: TextSize.xs))
                    .foregroundStyle(Color.textTertiary)
                    .textSelection(.enabled)
            }
            .padding(Space.s8)
        }
    }

    @ViewBuilder
    private var footerButtons: some View {
        switch phase {
        case .restoring:
            Button("Stop") { restoreTask?.cancel() }
        case .finished(_, let destination):
            Button("Show in Finder") { SystemIntegration.revealInFinder(destination) }
            Button("Open Folder") {
                dismiss()
                Task { await model.openWorkspace(destination) }
            }
            .keyboardShortcut(.defaultAction)
        default:
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Restore To…") { chooseDestination() }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
        }
    }

    private func loadFolders() async {
        phase = .loading
        switch await model.backup.remoteBackupFolders() {
        case .success(let result):
            folders = result
            selection = result.first { $0.prefix == model.workspace.rootURL.map { model.backup.remoteFolder(for: $0) } } ?? result.first
            phase = .choosing
        case .failure(let error):
            phase = .failed(error.message)
        }
    }

    private func chooseDestination() {
        guard let folder = selection, let parent = SystemIntegration.chooseRestoreLocation() else { return }
        let destination = Self.uniqueDestination(named: folder.name, in: parent)
        phase = .restoring(BackupProgress(completed: 0, total: 0, currentPath: nil))
        restoreTask = Task {
            let result = await model.backup.restore(folder, to: destination) { progress in
                Task { @MainActor in
                    if case .restoring = phase { phase = .restoring(progress) }
                }
            }
            switch result {
            case .success(let report): phase = .finished(report, destination)
            case .failure(let error): phase = .failed(error.message)
            }
        }
    }

    /// `Notes (Restored 2026-09-17)`，重名时追加序号。
    static func uniqueDestination(named name: String, in parent: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let base = String(localized: "\(name) (Restored \(formatter.string(from: Date())))")
        var candidate = parent.appendingPathComponent(base, isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base) \(index)", isDirectory: true)
            index += 1
        }
        return candidate
    }
}
