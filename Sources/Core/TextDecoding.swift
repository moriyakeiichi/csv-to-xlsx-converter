import Foundation

/// 入力ファイルの文字コード。auto は自動判定。
public enum SourceEncoding: String, CaseIterable, Sendable {
    case auto, utf8, cp932, eucJP, utf16

    public var label: String {
        switch self {
        case .auto: return "自動判定"
        case .utf8: return "UTF-8"
        case .cp932: return "Shift_JIS（CP932）"
        case .eucJP: return "EUC-JP"
        case .utf16: return "UTF-16"
        }
    }
}

public struct DecodedText: Sendable {
    public let text: String
    /// 結果欄に表示する文字コード名
    public let encodingName: String
    /// 利用者に知らせるべき注意（文字の置き換えなど）
    public let warnings: [String]
}

/// CP932・EUC-JPの対応表。Tools/make_tables.py で Python のコーデックから生成した .bin を読む。
public final class LegacyTables: Sendable {
    static let invalid: UInt32 = 0xFFFF_FFFF
    let cp932: [UInt32]
    let eucJP: [UInt32]
    let eucJP3: [UInt32]

    public init(directory: URL) throws {
        func load(_ name: String) throws -> [UInt32] {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), data.count == 65_536 * 4 else {
                throw ConversionError("文字コード表（\(name)）を読み込めません。アプリを入れ直してください。")
            }
            var table = [UInt32](repeating: 0, count: 65_536)
            data.withUnsafeBytes { raw in
                for i in 0..<65_536 {
                    let b = raw.baseAddress!.advanced(by: i * 4).assumingMemoryBound(to: UInt8.self)
                    table[i] = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
                }
            }
            return table
        }
        cp932 = try load("cp932.bin")
        eucJP = try load("eucjp.bin")
        eucJP3 = try load("eucjp3.bin")
    }
}

public struct TextDecoder: Sendable {
    let tables: LegacyTables

    public init(tables: LegacyTables) { self.tables = tables }

    // MARK: 公開API

    public func decode(_ data: Data, as choice: SourceEncoding) -> DecodedText {
        let bytes = [UInt8](data)
        switch choice {
        case .auto: return autoDecode(bytes)
        case .utf8:
            let start = hasUTF8BOM(bytes) ? 3 : 0
            let r = Self.decodeUTF8(bytes, from: start)
            return DecodedText(text: r.text, encodingName: "UTF-8（指定）", warnings: replacementWarning(r.replaced))
        case .cp932:
            let start = hasUTF8BOM(bytes) ? 3 : 0
            let r = decodeLegacy(bytes, from: start, kind: .cp932, replace: true)!
            return DecodedText(text: r.text, encodingName: "Shift_JIS（CP932・指定）", warnings: replacementWarning(r.replaced))
        case .eucJP:
            let start = hasUTF8BOM(bytes) ? 3 : 0
            let r = decodeLegacy(bytes, from: start, kind: .eucJP, replace: true)!
            return DecodedText(text: r.text, encodingName: "EUC-JP（指定）", warnings: replacementWarning(r.replaced))
        case .utf16:
            var bigEndian = false
            var start = 0
            if bytes.count >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF { bigEndian = true; start = 2 }
            else if bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE { start = 2 }
            else if let guess = guessUTF16WithoutBOM(bytes) { bigEndian = guess }
            let r = Self.decodeUTF16(bytes, from: start, bigEndian: bigEndian)
            return DecodedText(text: r.text, encodingName: bigEndian ? "UTF-16BE（指定）" : "UTF-16LE（指定）",
                               warnings: replacementWarning(r.replaced))
        }
    }

    // MARK: 自動判定

    private func autoDecode(_ bytes: [UInt8]) -> DecodedText {
        if bytes.isEmpty { return DecodedText(text: "", encodingName: "UTF-8", warnings: []) }

        // BOMで判断できるもの
        if bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE {
            let r = Self.decodeUTF16(bytes, from: 2, bigEndian: false)
            return DecodedText(text: r.text, encodingName: "UTF-16LE（BOM付き）", warnings: replacementWarning(r.replaced))
        }
        if bytes.count >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF {
            let r = Self.decodeUTF16(bytes, from: 2, bigEndian: true)
            return DecodedText(text: r.text, encodingName: "UTF-16BE（BOM付き）", warnings: replacementWarning(r.replaced))
        }
        if hasUTF8BOM(bytes) {
            let r = Self.decodeUTF8(bytes, from: 3)
            if r.replaced == 0 {
                return DecodedText(text: r.text, encodingName: "UTF-8（BOM付き）", warnings: [])
            }
            // BOMはUTF-8なのに本文が違う、という混在ファイル。BOMを外して日本語の旧来コードを試す。
            if let legacy = bestLegacy(bytes, from: 3) {
                return DecodedText(text: legacy.text, encodingName: legacy.name + "（先頭にUTF-8のBOMあり）",
                                   warnings: ["先頭にUTF-8のBOMが付いていますが、本文は\(legacy.name)でした。本文の文字コードで読み込みました。"] + legacy.warnings)
            }
        }

        // BOMなしUTF-16（Excelの「Unicodeテキスト」などで見かける）
        if let bigEndian = guessUTF16WithoutBOM(bytes) {
            let r = Self.decodeUTF16(bytes, from: 0, bigEndian: bigEndian)
            if r.replaced == 0 {
                return DecodedText(text: r.text, encodingName: bigEndian ? "UTF-16BE（BOMなし）" : "UTF-16LE（BOMなし）", warnings: [])
            }
        }

        let utf8 = Self.decodeUTF8(bytes, from: 0)
        if utf8.replaced == 0 {
            return DecodedText(text: utf8.text, encodingName: "UTF-8", warnings: [])
        }

        if let legacy = bestLegacy(bytes, from: 0) {
            return DecodedText(text: legacy.text, encodingName: legacy.name, warnings: legacy.warnings)
        }

        // どれでも読めない：最も置き換えの少ない方法で読み、必ず警告する
        let cp = decodeLegacy(bytes, from: 0, kind: .cp932, replace: true)!
        let euc = decodeLegacy(bytes, from: 0, kind: .eucJP, replace: true)!
        let candidates: [(String, String, Int)] = [
            ("Shift_JIS（CP932）", cp.text, cp.replaced),
            ("UTF-8", utf8.text, utf8.replaced),
            ("EUC-JP", euc.text, euc.replaced),
        ]
        let best = candidates.min { $0.2 < $1.2 }!
        return DecodedText(text: best.1, encodingName: best.0 + "（読めない文字を置換）",
                           warnings: ["どの文字コードでも正しく読めませんでした。\(best.0)として読み、読めなかった\(best.2)か所を「\u{FFFD}」に置き換えています。文字化けしている場合は、文字コードを指定して変換し直してください。"])
    }

    /// CP932とEUC-JPのうち、厳密に読めるものを選ぶ。両方読める場合は日本語らしさで判断する。
    private func bestLegacy(_ bytes: [UInt8], from start: Int) -> (text: String, name: String, warnings: [String])? {
        let cp = decodeLegacy(bytes, from: start, kind: .cp932, replace: false)
        let euc = decodeLegacy(bytes, from: start, kind: .eucJP, replace: false)
        switch (cp, euc) {
        case let (c?, nil): return (c.text, "Shift_JIS（CP932）", [])
        case let (nil, e?): return (e.text, "EUC-JP", [])
        case let (c?, e?):
            let cs = Self.japaneseScore(c.text), es = Self.japaneseScore(e.text)
            if es > cs { return (e.text, "EUC-JP", []) }
            if cs > es { return (c.text, "Shift_JIS（CP932）", []) }
            return (c.text, "Shift_JIS（CP932）",
                    ["文字コードをShift_JISかEUC-JPか判別しきれず、Shift_JIS（CP932）として読みました。文字化けしている場合は、文字コードに「EUC-JP」を指定して変換し直してください。"])
        default: return nil
        }
    }

    /// ひらがな・全角カタカナ・和文句読点の数。誤った文字コードで読むと、これらはほとんど現れない。
    static func japaneseScore(_ text: String) -> Int {
        var score = 0
        for s in text.unicodeScalars {
            switch s.value {
            case 0x3041...0x3096, 0x30A1...0x30FA, 0x3001, 0x3002, 0x300C, 0x300D, 0x30FC: score += 1
            default: break
            }
        }
        return score
    }

    private func hasUTF8BOM(_ b: [UInt8]) -> Bool { b.count >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF }

    /// BOMのないUTF-16らしいか。偶数・奇数位置のゼロバイトの偏りで判断する。nil=UTF-16らしくない、true=BE、false=LE
    private func guessUTF16WithoutBOM(_ b: [UInt8]) -> Bool? {
        let n = min(b.count, 4096) & ~1
        guard n >= 4 else { return nil }
        var evenZero = 0, oddZero = 0
        var i = 0
        while i < n {
            if b[i] == 0 { evenZero += 1 }
            if b[i + 1] == 0 { oddZero += 1 }
            i += 2
        }
        let pairs = n / 2
        if oddZero * 10 >= pairs * 3 && evenZero * 20 < pairs { return false }
        if evenZero * 10 >= pairs * 3 && oddZero * 20 < pairs { return true }
        return nil
    }

    private func replacementWarning(_ count: Int) -> [String] {
        count == 0 ? [] : ["指定の文字コードで読めない文字が\(count)か所あり、「\u{FFFD}」に置き換えました。"]
    }

    // MARK: 個別のデコード

    static func decodeUTF8(_ bytes: [UInt8], from start: Int) -> (text: String, replaced: Int) {
        var scalars = String.UnicodeScalarView()
        var replaced = 0
        var iterator = bytes[start...].makeIterator()
        var parser = Unicode.UTF8.ForwardParser()
        loop: while true {
            switch parser.parseScalar(from: &iterator) {
            case .valid(let encoded): scalars.append(Unicode.UTF8.decode(encoded))
            case .error: scalars.append("\u{FFFD}"); replaced += 1
            case .emptyInput: break loop
            }
        }
        return (String(scalars), replaced)
    }

    static func decodeUTF16(_ bytes: [UInt8], from start: Int, bigEndian: Bool) -> (text: String, replaced: Int) {
        var units: [UInt16] = []
        units.reserveCapacity(max(0, bytes.count - start) / 2)
        var i = start
        while i + 1 < bytes.count {
            units.append(bigEndian ? UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])
                                   : UInt16(bytes[i + 1]) << 8 | UInt16(bytes[i]))
            i += 2
        }
        var scalars = String.UnicodeScalarView()
        var replaced = 0
        var iterator = units.makeIterator()
        var parser = Unicode.UTF16.ForwardParser()
        loop: while true {
            switch parser.parseScalar(from: &iterator) {
            case .valid(let encoded): scalars.append(Unicode.UTF16.decode(encoded))
            case .error: scalars.append("\u{FFFD}"); replaced += 1
            case .emptyInput: break loop
            }
        }
        if (bytes.count - start) % 2 == 1 { scalars.append("\u{FFFD}"); replaced += 1 }
        return (String(scalars), replaced)
    }

    enum LegacyKind { case cp932, eucJP }

    /// replace=false のときは、1か所でも読めなければ nil。
    func decodeLegacy(_ bytes: [UInt8], from start: Int, kind: LegacyKind, replace: Bool) -> (text: String, replaced: Int)? {
        let table = kind == .cp932 ? tables.cp932 : tables.eucJP
        let invalid = LegacyTables.invalid
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(bytes.count)
        var replaced = 0
        var i = start
        let n = bytes.count
        while i < n {
            let b = Int(bytes[i])
            let single = table[b]
            if single != invalid, let s = Unicode.Scalar(single) {
                scalars.append(s); i += 1; continue
            }
            if kind == .eucJP && b == 0x8F && i + 2 < n {
                let v = tables.eucJP3[Int(bytes[i + 1]) << 8 | Int(bytes[i + 2])]
                if v != invalid, let s = Unicode.Scalar(v) { scalars.append(s); i += 3; continue }
            }
            if i + 1 < n {
                let v = table[b << 8 | Int(bytes[i + 1])]
                if v != invalid, let s = Unicode.Scalar(v) { scalars.append(s); i += 2; continue }
            }
            guard replace else { return nil }
            scalars.append("\u{FFFD}"); replaced += 1; i += 1
        }
        return (String(scalars), replaced)
    }
}

public struct ConversionError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
