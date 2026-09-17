import Foundation
import LiteMDDomain
import Observation

/// 重新启动后恢复工作状态所需的信息（spec §137）。不包含正文。
public struct SessionState: Codable, Sendable, Equatable {
    public var workspaceURL: URL?
    public var openDocumentURLs: [URL]
    public var activeDocumentURL: URL?
    public var editorMode: EditorMode
    public var sidebarTab: String?
    public var expandedFolderURLs: [URL]

    public init(
        workspaceURL: URL? = nil,
        openDocumentURLs: [URL] = [],
        activeDocumentURL: URL? = nil,
        editorMode: EditorMode = .split,
        sidebarTab: String? = nil,
        expandedFolderURLs: [URL] = []
    ) {
        self.workspaceURL = workspaceURL
        self.openDocumentURLs = openDocumentURLs
        self.activeDocumentURL = activeDocumentURL
        self.editorMode = editorMode
        self.sidebarTab = sidebarTab
        self.expandedFolderURLs = expandedFolderURLs
    }
}

struct RecentItems: Codable, Sendable {
    var files: [URL] = []
    var workspaces: [URL] = []
}

/// Recent 与 Session 持久化（spec §63、§136）。
@MainActor
@Observable
public final class SessionService {
    public static let maximumRecentItems = 15

    public private(set) var recentFiles: [URL] = []
    public private(set) var recentWorkspaces: [URL] = []

    @ObservationIgnored private let store: any StateStoring

    public init(store: any StateStoring) {
        self.store = store
    }

    public func load() async {
        let items = await store.load(RecentItems.self, key: "recent") ?? RecentItems()
        recentFiles = items.files
        recentWorkspaces = items.workspaces
    }

    public func noteOpenedFile(_ url: URL) {
        recentFiles = Self.pushing(url.standardizedFileURL, onto: recentFiles)
        persistRecents()
    }

    public func noteOpenedWorkspace(_ url: URL) {
        recentWorkspaces = Self.pushing(url.standardizedFileURL, onto: recentWorkspaces)
        persistRecents()
    }

    public func removeRecent(_ url: URL) {
        recentFiles.removeAll { $0 == url }
        recentWorkspaces.removeAll { $0 == url }
        persistRecents()
    }

    public func clearRecents() {
        recentFiles = []
        recentWorkspaces = []
        persistRecents()
    }

    public func saveSession(_ state: SessionState) async {
        await store.save(state, key: "session")
    }

    public func loadSession() async -> SessionState? {
        await store.load(SessionState.self, key: "session")
    }

    private func persistRecents() {
        let items = RecentItems(files: recentFiles, workspaces: recentWorkspaces)
        let store = self.store
        Task { await store.save(items, key: "recent") }
    }

    static func pushing(_ url: URL, onto list: [URL]) -> [URL] {
        var result = list.filter { $0 != url }
        result.insert(url, at: 0)
        return Array(result.prefix(maximumRecentItems))
    }
}
