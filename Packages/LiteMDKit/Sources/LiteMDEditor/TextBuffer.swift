import Foundation
import LiteMDDomain

/// 正文缓冲区（spec §88）。
///
/// 其他模块不直接持有、修改正文字符串，所有变化都经过 `replaceCharacters`，
/// 以便统一 Revision、Autosave、Parse、Recovery。
/// 接口不假设底层是普通 String，未来可以替换为 Rope / Piece Table。
@MainActor
public protocol TextBuffer: AnyObject {
    /// UTF-16 code unit 数量。
    var length: Int { get }
    /// 每次有效修改 +1。
    var revision: Int { get }

    /// 当前正文的不可变副本，可安全传给后台任务。
    func snapshot() -> String
    func substring(in range: NSRange) -> String

    func replaceCharacters(in range: NSRange, with string: String)
    func replaceAll(with string: String)
}

@MainActor
public final class StringTextBuffer: TextBuffer {
    private let storage: NSMutableString
    public private(set) var revision: Int

    public init(_ text: String = "", revision: Int = 0) {
        self.storage = NSMutableString(string: text)
        self.revision = revision
    }

    public var length: Int { storage.length }

    public func snapshot() -> String {
        String(storage)
    }

    public func substring(in range: NSRange) -> String {
        storage.substring(with: range)
    }

    public func replaceCharacters(in range: NSRange, with string: String) {
        precondition(NSMaxRange(range) <= storage.length, "TextBuffer 编辑区间越界")
        if range.length == 0, string.isEmpty { return }
        storage.replaceCharacters(in: range, with: string)
        revision += 1
    }

    public func replaceAll(with string: String) {
        storage.setString(string)
        revision += 1
    }
}
