import Foundation

public enum DelimiterChoice: String, CaseIterable, Sendable {
    case auto, comma, tab, semicolon

    public var label: String {
        switch self {
        case .auto: return "自動判定"
        case .comma: return "カンマ"
        case .tab: return "タブ"
        case .semicolon: return "セミコロン"
        }
    }
    var scalar: Unicode.Scalar? {
        switch self {
        case .auto: return nil
        case .comma: return ","
        case .tab: return "\t"
        case .semicolon: return ";"
        }
    }
}

public enum Delimited {
    private enum State { case fieldStart, unquoted, quoted, afterQuote }

    /// 区切り文字・二重引用符・引用内の改行・""によるエスケープに対応。
    /// 閉じていない引用符はファイル末尾までを1セルとして扱う（エラーにしない）。
    /// 空行は空の行として残す。
    public static func parse(_ text: String, delimiter: Unicode.Scalar) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var state = State.fieldStart
        var started = false
        var skipLF = false
        for c in text.unicodeScalars {
            if skipLF {
                skipLF = false
                if c == "\n" { continue }
            }
            if state == .quoted {
                if c == "\"" { state = .afterQuote } else { field.append(c) }
                continue
            }
            if c == "\r" || c == "\n" {
                if started || !row.isEmpty { row.append(String(field)) }
                rows.append(row)
                row = []
                field = String.UnicodeScalarView()
                state = .fieldStart
                started = false
                if c == "\r" { skipLF = true }
            } else if c == delimiter {
                row.append(String(field))
                field = String.UnicodeScalarView()
                state = .fieldStart
                started = true
            } else if c == "\"" && state == .fieldStart {
                state = .quoted
                started = true
            } else if c == "\"" && state == .afterQuote {
                field.append(c)
                state = .quoted
            } else {
                field.append(c)
                state = .unquoted
                started = true
            }
        }
        if started || !row.isEmpty {
            row.append(String(field))
            rows.append(row)
        }
        return rows
    }

    /// 先頭30レコードで、引用符の外にある区切り候補の数がそろっているものを選ぶ。
    public static func detectDelimiter(_ text: String) -> Unicode.Scalar {
        let candidates: [Unicode.Scalar] = [",", "\t", ";"]
        var counts: [[Int]] = Array(repeating: [], count: candidates.count)
        var current = Array(repeating: 0, count: candidates.count)
        var inQuotes = false
        var lines = 0
        var lineHasContent = false
        var examined = 0
        for c in text.unicodeScalars {
            examined += 1
            if examined > 200_000 || lines >= 30 { break }
            if c == "\"" { inQuotes.toggle(); lineHasContent = true; continue }
            if inQuotes { continue }
            if c == "\n" || c == "\r" {
                if lineHasContent {
                    for k in candidates.indices { counts[k].append(current[k]) }
                    lines += 1
                }
                current = Array(repeating: 0, count: candidates.count)
                lineHasContent = false
                continue
            }
            lineHasContent = true
            if let k = candidates.firstIndex(of: c) { current[k] += 1 }
        }
        if lineHasContent && lines < 30 {
            for k in candidates.indices { counts[k].append(current[k]) }
        }
        var best = 0
        var bestScore = -1
        for k in candidates.indices {
            let list = counts[k]
            guard !list.isEmpty else { continue }
            var frequency: [Int: Int] = [:]
            for v in list { frequency[v, default: 0] += 1 }
            let (mode, hits) = frequency.max { a, b in a.value == b.value ? a.key < b.key : a.value < b.value }!
            guard mode > 0 else { continue }
            let score = hits * 1000 / list.count * 100 + min(mode, 99)
            if score > bestScore { bestScore = score; best = k }
        }
        return candidates[best]
    }

    public static func name(of delimiter: Unicode.Scalar) -> String {
        switch delimiter {
        case ",": return "カンマ区切り"
        case "\t": return "タブ区切り"
        case ";": return "セミコロン区切り"
        default: return "区切り文字「\(delimiter)」"
        }
    }

    /// UTF-8（BOM付き）・カンマ区切り・CRLFのCSVを作る。必要なセルだけ二重引用符で囲む。
    public static func encodeCSV(_ rows: [[String]]) -> Data {
        var out = [UInt8]([0xEF, 0xBB, 0xBF])
        for row in rows {
            for (i, cell) in row.enumerated() {
                if i > 0 { out.append(0x2C) }
                let needsQuotes = (row.count == 1 && cell.isEmpty) || cell.unicodeScalars.contains {
                    $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n"
                }
                if needsQuotes {
                    out.append(0x22)
                    for byte in cell.utf8 {
                        if byte == 0x22 { out.append(0x22) }
                        out.append(byte)
                    }
                    out.append(0x22)
                } else {
                    out.append(contentsOf: cell.utf8)
                }
            }
            out.append(0x0D); out.append(0x0A)
        }
        return Data(out)
    }
}
