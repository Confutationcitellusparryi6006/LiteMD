import Foundation

public enum TextEncoding: String, Codable, Sendable, CaseIterable {
    case utf8
    case utf8WithBOM
    case utf16LittleEndian
    case utf16BigEndian

    public var displayName: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf8WithBOM: "UTF-8 BOM"
        case .utf16LittleEndian: "UTF-16 LE"
        case .utf16BigEndian: "UTF-16 BE"
        }
    }
}

public enum LineEnding: String, Codable, Sendable, CaseIterable {
    case lf
    case crlf
    case cr

    public var sequence: String {
        switch self {
        case .lf: "\n"
        case .crlf: "\r\n"
        case .cr: "\r"
        }
    }

    public var displayName: String {
        switch self {
        case .lf: "LF"
        case .crlf: "CRLF"
        case .cr: "CR"
        }
    }
}

public struct DecodedText: Equatable, Sendable {
    /// 统一使用 LF 的正文。编辑器内部永远只看到 `\n`。
    public var text: String
    public var encoding: TextEncoding
    /// 文件中占多数的换行符，保存时还原。
    public var lineEnding: LineEnding

    public init(text: String, encoding: TextEncoding, lineEnding: LineEnding) {
        self.text = text
        self.encoding = encoding
        self.lineEnding = lineEnding
    }
}

/// 文本编解码规则（spec §45）。
///
/// - 默认 UTF-8；识别 UTF-8 BOM 与带 BOM 的 UTF-16。
/// - 非法 UTF-8 直接报错，绝不以错误编码打开后再写回，避免破坏文件。
/// - 编辑器内部统一 LF，保存时还原为文件原本占多数的换行符。混合换行的文件保存后会被统一。
public enum TextCodec {
    public static func decode(_ data: Data) throws(LiteMDError) -> DecodedText {
        let bytes = [UInt8](data)
        let encoding: TextEncoding
        let decoded: String?

        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            encoding = .utf8WithBOM
            decoded = String(validating: bytes.dropFirst(3), as: UTF8.self)
        } else if bytes.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LittleEndian
            decoded = String(data: Data(bytes.dropFirst(2)), encoding: .utf16LittleEndian)
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BigEndian
            decoded = String(data: Data(bytes.dropFirst(2)), encoding: .utf16BigEndian)
        } else {
            encoding = .utf8
            decoded = String(validating: bytes, as: UTF8.self)
        }

        guard let raw = decoded else {
            throw LiteMDError(kind: .encoding, reason: .unsupportedEncoding)
        }
        let (normalized, lineEnding) = normalizeLineEndings(raw)
        return DecodedText(text: normalized, encoding: encoding, lineEnding: lineEnding)
    }

    public static func encode(_ text: String, encoding: TextEncoding, lineEnding: LineEnding) -> Data {
        // 防御：即便缓冲区里混入了 CR，也先统一，再转换为目标换行符，避免产生 \r\r\n。
        var body = normalizeLineEndings(text).text
        if lineEnding != .lf {
            body = body.replacingOccurrences(of: "\n", with: lineEnding.sequence)
        }

        switch encoding {
        case .utf8:
            return Data(body.utf8)
        case .utf8WithBOM:
            return Data([0xEF, 0xBB, 0xBF]) + Data(body.utf8)
        case .utf16LittleEndian:
            var data = Data([0xFF, 0xFE])
            for unit in body.utf16 {
                data.append(UInt8(unit & 0xFF))
                data.append(UInt8(unit >> 8))
            }
            return data
        case .utf16BigEndian:
            var data = Data([0xFE, 0xFF])
            for unit in body.utf16 {
                data.append(UInt8(unit >> 8))
                data.append(UInt8(unit & 0xFF))
            }
            return data
        }
    }

    /// 统一为 LF，并返回原文中占多数的换行符（无换行时为 LF）。
    public static func normalizeLineEndings(_ text: String) -> (text: String, dominant: LineEnding) {
        var lf = 0
        var crlf = 0
        var cr = 0
        var hasCarriageReturn = false

        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let unit = units[index]
            if unit == 0x0D {
                hasCarriageReturn = true
                if index + 1 < units.count, units[index + 1] == 0x0A {
                    crlf += 1
                    index += 2
                    continue
                }
                cr += 1
            } else if unit == 0x0A {
                lf += 1
            }
            index += 1
        }

        let dominant: LineEnding
        if crlf > lf, crlf >= cr {
            dominant = .crlf
        } else if cr > lf, cr > crlf {
            dominant = .cr
        } else {
            dominant = .lf
        }

        guard hasCarriageReturn else { return (text, dominant) }

        var output = [UInt16]()
        output.reserveCapacity(units.count)
        index = 0
        while index < units.count {
            let unit = units[index]
            if unit == 0x0D {
                output.append(0x0A)
                if index + 1 < units.count, units[index + 1] == 0x0A {
                    index += 1
                }
            } else {
                output.append(unit)
            }
            index += 1
        }
        return (String(decoding: output, as: UTF16.self), dominant)
    }
}
