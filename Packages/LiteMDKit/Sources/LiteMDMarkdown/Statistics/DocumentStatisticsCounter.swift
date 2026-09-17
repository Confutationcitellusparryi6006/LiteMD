import Foundation
import LiteMDDomain

/// 文档统计（spec §25、§71）。
///
/// 规则（跨平台一致）：
/// - 中日文字符（汉字、假名等）每个字计 1 个词；
/// - 其他文字按连续的字母 / 数字计 1 个词，词内的 `'` 与 `’` 不拆分；
/// - 字符数为用户可见字符（grapheme cluster）数量，不含换行；
/// - 行数 = 换行数 + 1；
/// - 阅读时间：拉丁词 250 / 分钟，中日文 400 字 / 分钟，向上取整。
public enum DocumentStatisticsCounter {
    public static func compute(_ text: String) -> DocumentStatistics {
        var latinWords = 0
        var cjkCharacters = 0
        var newlines = 0
        var inWord = false

        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value == 0x0A {
                newlines += 1
                inWord = false
                continue
            }
            if isCJK(value) {
                cjkCharacters += 1
                inWord = false
                continue
            }
            let properties = scalar.properties
            if properties.isAlphabetic || properties.numericType != nil {
                if !inWord {
                    latinWords += 1
                    inWord = true
                }
            } else if inWord, value == 0x27 || value == 0x2019 || properties.generalCategory == .nonspacingMark || properties.generalCategory == .spacingMark {
                continue
            } else {
                inWord = false
            }
        }

        let characters = text.count - newlines
        let minutes = Double(latinWords) / 250 + Double(cjkCharacters) / 400
        return DocumentStatistics(
            words: latinWords + cjkCharacters,
            characters: max(0, characters),
            lines: newlines + 1,
            readingMinutes: Int(minutes.rounded(.up))
        )
    }

    static func isCJK(_ value: UInt32) -> Bool {
        switch value {
        case 0x4E00...0x9FFF, // CJK Unified Ideographs
             0x3400...0x4DBF, // Extension A
             0x20000...0x2EBEF, // Extensions B–F
             0x30000...0x323AF, // Extensions G–H
             0xF900...0xFAFF, // Compatibility Ideographs
             0x2F800...0x2FA1F,
             0x3040...0x309F, // Hiragana
             0x30A0...0x30FF, // Katakana
             0x31F0...0x31FF,
             0x3100...0x312F: // Bopomofo
            true
        default:
            false
        }
    }
}
