import Foundation

/// 统一错误类型（spec §159）。
///
/// 底层系统错误（例如 `NSCocoaErrorDomain Code 513`）只放在 `technicalDetails`，
/// 不直接展示给普通用户。
public struct LiteMDError: Error, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case file
        case encoding
        case save
        case conflict
        case parse
        case workspace
        case recovery
        case asset
    }

    public enum Reason: String, Sendable {
        case notFound
        case permissionDenied
        case alreadyExists
        case diskFull
        case readOnlyVolume
        case unsupportedEncoding
        case isDirectory
        case fileTooLarge
        case externalModification
        case externalDeletion
        case requiresSavedDocument
        case invalidName
        case unsupportedFileType
        case unknown
    }

    public var kind: Kind
    public var reason: Reason
    public var fileName: String?
    public var technicalDetails: String?

    public init(kind: Kind, reason: Reason, fileName: String? = nil, technicalDetails: String? = nil) {
        self.kind = kind
        self.reason = reason
        self.fileName = fileName
        self.technicalDetails = technicalDetails
    }

    public func with(kind: Kind? = nil, fileName: String? = nil) -> LiteMDError {
        var copy = self
        if let kind { copy.kind = kind }
        if let fileName { copy.fileName = fileName }
        return copy
    }

    /// 例如："Unable to save README.md."
    public var title: String {
        let name = fileName ?? "the document"
        switch kind {
        case .file: return "Unable to open \(name)."
        case .encoding: return "Unable to open \(name)."
        case .save: return "Unable to save \(name)."
        case .conflict: return "\(name) was changed outside LiteMD."
        case .parse: return "Unable to read \(name)."
        case .workspace: return "The folder operation could not be completed."
        case .recovery: return "Unable to recover \(name)."
        case .asset: return "Unable to insert the image."
        }
    }

    /// 例如："LiteMD does not have permission to write to this folder."
    public var message: String {
        switch reason {
        case .notFound: "The file or folder no longer exists. It may have been moved or deleted."
        case .permissionDenied: "LiteMD does not have permission to access this location."
        case .alreadyExists: "An item with the same name already exists."
        case .diskFull: "There is not enough disk space."
        case .readOnlyVolume: "This location is read-only."
        case .unsupportedEncoding: "The file is not UTF-8 or UTF-16 encoded. LiteMD did not open it to avoid damaging its contents."
        case .isDirectory: "This is a folder, not a file."
        case .fileTooLarge: "The file is too large to open in the editor."
        case .externalModification: "The file on disk was modified by another app. LiteMD did not overwrite it."
        case .externalDeletion: "The file on disk was deleted or moved."
        case .requiresSavedDocument: "Save the document to a file first."
        case .invalidName: "The name is not valid."
        case .unsupportedFileType: "This file type is not supported."
        case .unknown: "An unexpected error occurred."
        }
    }
}
