import Foundation

/// 文件夹颜色。具体色值由各平台按浅色 / 深色外观提供。
public enum FolderColor: String, CaseIterable, Codable, Identifiable, Sendable {
    case red
    case orange
    case yellow
    case green
    case teal
    case blue
    case purple
    case gray

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .teal: "Teal"
        case .blue: "Blue"
        case .purple: "Purple"
        case .gray: "Gray"
        }
    }
}

/// 预设的文件夹图标（SF Symbols 名称）。
public enum FolderSymbol: String, CaseIterable, Codable, Identifiable, Sendable {
    case folder
    case work
    case study
    case journal
    case ideas
    case project
    case archive
    case favorite
    case pinned
    case library
    case code
    case images
    case music
    case travel
    case finance
    case health
    case home
    case people
    case calendar
    case tag
    case flag
    case locked
    case cloud
    case inbox

    public var id: String { rawValue }

    public var systemName: String {
        switch self {
        case .folder: "folder"
        case .work: "briefcase"
        case .study: "graduationcap"
        case .journal: "book.closed"
        case .ideas: "lightbulb"
        case .project: "hammer"
        case .archive: "archivebox"
        case .favorite: "star"
        case .pinned: "pin"
        case .library: "books.vertical"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .images: "photo"
        case .music: "music.note"
        case .travel: "airplane"
        case .finance: "creditcard"
        case .health: "heart"
        case .home: "house"
        case .people: "person.2"
        case .calendar: "calendar"
        case .tag: "tag"
        case .flag: "flag"
        case .locked: "lock"
        case .cloud: "cloud"
        case .inbox: "tray"
        }
    }

    public var displayName: String {
        switch self {
        case .folder: "Folder"
        case .work: "Work"
        case .study: "Study"
        case .journal: "Journal"
        case .ideas: "Ideas"
        case .project: "Project"
        case .archive: "Archive"
        case .favorite: "Favorite"
        case .pinned: "Pinned"
        case .library: "Books"
        case .code: "Code"
        case .images: "Images"
        case .music: "Music"
        case .travel: "Travel"
        case .finance: "Finance"
        case .health: "Health"
        case .home: "Home"
        case .people: "People"
        case .calendar: "Calendar"
        case .tag: "Tag"
        case .flag: "Flag"
        case .locked: "Private"
        case .cloud: "Cloud"
        case .inbox: "Inbox"
        }
    }
}

/// 单个文件夹的外观。全部为默认值时不保存。
public struct FolderAppearance: Codable, Equatable, Sendable {
    public var color: FolderColor?
    public var symbol: FolderSymbol?
    /// 文件夹名称是否使用同样的颜色（默认只给图标上色）。
    public var tintsName: Bool

    public init(color: FolderColor? = nil, symbol: FolderSymbol? = nil, tintsName: Bool = false) {
        self.color = color
        self.symbol = symbol
        self.tintsName = tintsName
    }

    public var isDefault: Bool {
        color == nil && (symbol == nil || symbol == .folder) && !tintsName
    }
}

/// 按文件夹路径保存的外观。数据存放在应用目录，不写入用户的文件夹。
public struct FolderAppearanceMap: Codable, Equatable, Sendable {
    public private(set) var entries: [String: FolderAppearance] = [:]

    public init() {}

    private static func key(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    public func appearance(for url: URL) -> FolderAppearance? {
        entries[Self.key(url)]
    }

    public mutating func set(_ appearance: FolderAppearance, for url: URL) {
        entries[Self.key(url)] = appearance.isDefault ? nil : appearance
    }

    /// 文件夹被重命名或移动：自身与所有子文件夹的外观跟着迁移。
    public mutating func itemMoved(from source: URL, to destination: URL) {
        let old = Self.key(source)
        let new = Self.key(destination)
        guard old != new else { return }
        var updated: [String: FolderAppearance] = [:]
        for (path, appearance) in entries {
            if path == old {
                updated[new] = appearance
            } else if path.hasPrefix(old + "/") {
                updated[new + path.dropFirst(old.count)] = appearance
            } else {
                updated[path] = appearance
            }
        }
        entries = updated
    }

    /// 文件夹被移到废纸篓：移除自身与子文件夹的外观。
    public mutating func itemRemoved(at url: URL) {
        let path = Self.key(url)
        entries = entries.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
    }
}
