#!/usr/bin/env swift
// 为更新包签名并生成更新源 JSON。
//
// 用法：swift scripts/sign-update.swift <私钥文件> <更新包.zip> <版本> <构建号> <下载地址> [最低系统版本] [更新说明.json]
// 更新说明 JSON 形如 {"en": "...", "zh-Hans": "..."}。
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 6 else {
    FileHandle.standardError.write(Data("usage: swift scripts/sign-update.swift <private-key> <package.zip> <version> <build> <url> [minimum-macos] [notes.json]\n".utf8))
    exit(64)
}
let keyText = try String(contentsOfFile: arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
guard let keyData = Data(base64Encoded: keyText) else {
    FileHandle.standardError.write(Data("invalid private key\n".utf8))
    exit(65)
}
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
let package = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
let signature = try key.signature(for: package).base64EncodedString()

var feed: [String: Any] = [
    "version": arguments[3],
    "build": arguments[4],
    "url": arguments[5],
    "length": package.count,
    "signature": signature,
    "publishedAt": ISO8601DateFormatter().string(from: Date()),
]
if arguments.count >= 7, !arguments[6].isEmpty {
    feed["minimumSystemVersion"] = arguments[6]
}
if arguments.count >= 8 {
    let notes = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments[7])))
    feed["notes"] = notes
}
let data = try JSONSerialization.data(withJSONObject: feed, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
