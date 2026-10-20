import Foundation
#if canImport(Compression)
import Compression
#endif

/// 1シートだけのExcelブック（.xlsx）を作る。外部ライブラリ・外部プロセスは使わない。
public struct XLSXWriter {
    public static let maxRows = 1_048_576
    public static let maxColumns = 16_384
    public static let maxCellCharacters = 32_767

    public struct Result {
        public let data: Data
        public let warnings: [String]
        public let counts: CellCounts
    }

    public static func make(rows: [[String]], sheetName: String, options: TypingOptions) throws -> Result {
        var warnings: [String] = []
        var counts = CellCounts()
        var styles = StyleTable()

        var rowCount = rows.count
        if rowCount > maxRows {
            warnings.append("Excelの上限（\(maxRows)行）を超えたため、\(maxRows + 1)行目以降（\(rowCount - maxRows)行）は含めていません。")
            rowCount = maxRows
        }
        var columnCount = rows.prefix(rowCount).map(\.count).max() ?? 0
        if columnCount > maxColumns {
            warnings.append("Excelの上限（\(maxColumns)列）を超えたため、\(maxColumns + 1)列目以降は含めていません。")
            columnCount = maxColumns
        }
        var truncatedCells = 0

        // 列幅：先頭2000行の表示幅から決める
        var widths = Array(repeating: 0, count: columnCount)
        for row in rows.prefix(min(rowCount, 2000)) {
            for (c, cell) in row.prefix(columnCount).enumerated() {
                widths[c] = max(widths[c], displayWidth(cell))
            }
        }

        var sheet = ByteBuffer()
        sheet.append("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n")
        sheet.append("<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">")
        let lastRef = columnCount > 0 && rowCount > 0 ? columnName(columnCount - 1) + String(rowCount) : "A1"
        sheet.append("<dimension ref=\"A1:\(lastRef)\"/>")
        sheet.append("<sheetViews><sheetView workbookViewId=\"0\"/></sheetViews>")
        sheet.append("<sheetFormatPr defaultRowHeight=\"18\"/>")
        if columnCount > 0 {
            sheet.append("<cols>")
            for (c, w) in widths.enumerated() {
                let width = min(max(w + 2, 8), 60)
                sheet.append("<col min=\"\(c + 1)\" max=\"\(c + 1)\" width=\"\(width)\" customWidth=\"1\"/>")
            }
            sheet.append("</cols>")
        }
        sheet.append("<sheetData>")
        let columnNames = (0..<columnCount).map(columnName)
        for r in 0..<rowCount {
            let row = rows[r]
            if row.isEmpty || row.allSatisfy(\.isEmpty) { continue }
            sheet.append("<row r=\"\(r + 1)\">")
            for (c, raw) in row.prefix(columnCount).enumerated() {
                var cell = CellTyping.classify(raw, options: options)
                counts.add(cell)
                let ref = columnNames[c] + String(r + 1)
                switch cell.kind {
                case .empty:
                    continue
                case .number, .date:
                    let s = styles.index(format: cell.format, wrap: false)
                    sheet.append("<c r=\"\(ref)\"" + (s == 0 ? "" : " s=\"\(s)\"") + "><v>\(cell.value)</v></c>")
                case .text:
                    var text = normalizeNewlines(cell.value)
                    if text.utf16.count > maxCellCharacters {
                        text = truncate(text, toUTF16: maxCellCharacters)
                        truncatedCells += 1
                    }
                    cell.value = text
                    let s = styles.index(format: cell.format, wrap: text.contains("\n"))
                    sheet.append("<c r=\"\(ref)\"" + (s == 0 ? "" : " s=\"\(s)\"") + " t=\"inlineStr\"><is><t xml:space=\"preserve\">")
                    appendEscaped(text, to: &sheet)
                    sheet.append("</t></is></c>")
                }
            }
            sheet.append("</row>")
        }
        sheet.append("</sheetData>")
        sheet.append("<pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/>")
        // 「数値が文字列として保存されています」の緑の三角を出さない
        sheet.append("<ignoredErrors><ignoredError sqref=\"A1:\(lastRef)\" numberStoredAsText=\"1\"/></ignoredErrors>")
        sheet.append("</worksheet>")

        if truncatedCells > 0 {
            warnings.append("Excelの上限（1セル\(maxCellCharacters)文字）を超えた\(truncatedCells)セルは、上限までで切り詰めました。")
        }

        let name = safeSheetName(sheetName)
        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><bookViews><workbookView/></bookViews><sheets><sheet name="\(escapeAttribute(name))" sheetId="1" r:id="rId1"/></sheets></workbook>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>
        """
        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """
        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
        """
        var zip = ZipWriter()
        try zip.add("[Content_Types].xml", Array(contentTypes.utf8))
        try zip.add("_rels/.rels", Array(rootRels.utf8))
        try zip.add("xl/workbook.xml", Array(workbook.utf8))
        try zip.add("xl/_rels/workbook.xml.rels", Array(workbookRels.utf8))
        try zip.add("xl/styles.xml", Array(styles.xml().utf8))
        try zip.add("xl/worksheets/sheet1.xml", sheet.bytes)
        return Result(data: try zip.finish(), warnings: warnings, counts: counts)
    }

    // MARK: 補助

    static func columnName(_ index: Int) -> String {
        var n = index + 1
        var name = ""
        while n > 0 {
            let r = (n - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + r))) + name
            n = (n - 1) / 26
        }
        return name
    }

    /// 全角文字を2、それ以外を1として数えた、最も長い行の幅
    static func displayWidth(_ s: String) -> Int {
        var best = 0, current = 0, count = 0
        for u in s.unicodeScalars {
            count += 1
            if count > 400 { break }
            if u == "\n" || u == "\r" { best = max(best, current); current = 0; continue }
            let v = u.value
            let wide = (v >= 0x1100 && v <= 0x115F) || (v >= 0x2E80 && v <= 0xA4CF) || (v >= 0xAC00 && v <= 0xD7A3) ||
                (v >= 0xF900 && v <= 0xFAFF) || (v >= 0xFE30 && v <= 0xFE4F) || (v >= 0xFF00 && v <= 0xFF60) ||
                (v >= 0xFFE0 && v <= 0xFFE6) || v >= 0x1F300
            current += wide ? 2 : 1
        }
        return max(best, current)
    }

    static func normalizeNewlines(_ s: String) -> String {
        guard s.unicodeScalars.contains("\r") else { return s }
        return s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func truncate(_ s: String, toUTF16 limit: Int) -> String {
        var out = String.UnicodeScalarView()
        var used = 0
        for u in s.unicodeScalars {
            let w = u.value > 0xFFFF ? 2 : 1
            if used + w > limit { break }
            out.append(u); used += w
        }
        return String(out)
    }

    static func safeSheetName(_ name: String) -> String {
        let banned: Set<Character> = ["[", "]", ":", "*", "?", "/", "\\"]
        var cleaned = String(name.map { banned.contains($0) ? "_" : $0 })
        while cleaned.hasPrefix("'") { cleaned.removeFirst() }
        while cleaned.hasSuffix("'") { cleaned.removeLast() }
        var limited = ""
        var units = 0
        for ch in cleaned {
            let w = String(ch).utf16.count
            if units + w > 31 { break }
            limited.append(ch); units += w
        }
        let trimmed = limited.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.caseInsensitiveCompare("History") == .orderedSame ? "Sheet1" : trimmed
    }

    static func escapeAttribute(_ s: String) -> String {
        var b = ByteBuffer()
        appendEscaped(s, to: &b)
        return String(decoding: b.bytes, as: UTF8.self)
    }

    /// XMLとして安全な形で追加する。XMLに書けない制御文字は _xHHHH_ に、元からある _xHHHH_ は _x005F_xHHHH_ にする。
    static func appendEscaped(_ s: String, to b: inout ByteBuffer) {
        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let u = scalars[i]
            switch u {
            case "&": b.append("&amp;")
            case "<": b.append("&lt;")
            case ">": b.append("&gt;")
            case "\"": b.append("&quot;")
            case "_":
                if looksLikeEscape(scalars, at: i) { b.append("_x005F_") } else { b.append("_") }
            default:
                let v = u.value
                let valid = v == 0x9 || v == 0xA || v == 0xD || (v >= 0x20 && v <= 0xD7FF) ||
                    (v >= 0xE000 && v <= 0xFFFD) || v >= 0x10000
                if valid { b.append(u) } else { b.append(String(format: "_x%04X_", v)) }
            }
            i += 1
        }
    }

    static func looksLikeEscape(_ s: [Unicode.Scalar], at i: Int) -> Bool {
        guard i + 6 < s.count, s[i + 1] == "x" || s[i + 1] == "X", s[i + 6] == "_" else { return false }
        return s[(i + 2)...(i + 5)].allSatisfy { $0.properties.isASCIIHexDigit }
    }
}

public struct CellCounts: Sendable, Equatable {
    public var numbers = 0
    public var dates = 0
    public var texts = 0
    public var protected = 0
    public var longNumbers = 0
    public init() {}
    mutating func add(_ cell: TypedCell) {
        switch cell.kind {
        case .empty: break
        case .number: numbers += 1; if cell.isLongNumber { longNumbers += 1 }
        case .date: dates += 1
        case .text: texts += 1; if cell.isProtected { protected += 1 }
        }
    }
}

/// 表示形式と折り返しの組み合わせごとにスタイル番号を割り当てる
struct StyleTable {
    private var keys: [String] = [""]  // 0番は標準
    private var entries: [(numFmtId: Int, wrap: Bool)] = [(0, false)]
    private var customFormats: [(id: Int, code: String)] = []
    private static let builtIn: [String: Int] = ["0": 1, "0.00": 2, "#,##0": 3, "#,##0.00": 4, "0%": 9, "0.00%": 10, "@": 49]

    mutating func index(format: String?, wrap: Bool) -> Int {
        let key = (format ?? "") + (wrap ? "\u{1}w" : "")
        if let i = keys.firstIndex(of: key) { return i }
        var id = 0
        if let format {
            if let b = Self.builtIn[format] { id = b }
            else if let c = customFormats.first(where: { $0.code == format }) { id = c.id }
            else { id = 164 + customFormats.count; customFormats.append((id, format)) }
        }
        keys.append(key)
        entries.append((id, wrap))
        return keys.count - 1
    }

    func xml() -> String {
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        if !customFormats.isEmpty {
            s += "<numFmts count=\"\(customFormats.count)\">"
            for f in customFormats { s += "<numFmt numFmtId=\"\(f.id)\" formatCode=\"\(XLSXWriter.escapeAttribute(f.code))\"/>" }
            s += "</numFmts>"
        }
        s += "<fonts count=\"1\"><font><sz val=\"12\"/><name val=\"游ゴシック\"/><family val=\"3\"/><charset val=\"128\"/></font></fonts>"
        s += "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>"
        s += "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"
        s += "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
        s += "<cellXfs count=\"\(entries.count)\">"
        for e in entries {
            s += "<xf numFmtId=\"\(e.numFmtId)\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\""
            if e.numFmtId != 0 { s += " applyNumberFormat=\"1\"" }
            if e.wrap { s += " applyAlignment=\"1\"><alignment wrapText=\"1\" vertical=\"top\"/></xf>" } else { s += "/>" }
        }
        s += "</cellXfs><cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>"
        return s
    }
}

struct ByteBuffer {
    var bytes: [UInt8] = []
    mutating func append(_ s: String) { bytes.append(contentsOf: s.utf8) }
    mutating func append(_ u: Unicode.Scalar) { bytes.append(contentsOf: String(u).utf8) }
}

/// 最小限のZIP書き出し（.xlsxの入れ物）。日時は固定にして、同じ入力からは同じバイト列ができるようにする。
struct ZipWriter {
    private var output: [UInt8] = []
    private var central: [UInt8] = []
    private var count = 0

    mutating func add(_ name: String, _ data: [UInt8]) throws {
        let crc = CRC32.checksum(data)
        var method: UInt16 = 0
        var stored = data
        if let deflated = Self.deflate(data), deflated.count < data.count {
            method = 8
            stored = deflated
        }
        guard output.count < 0xFFFF_FFFF, stored.count < 0xFFFF_FFFF, data.count < 0xFFFF_FFFF else {
            throw ConversionError("データが大きすぎて.xlsxにできません。CSV出力を使ってください。")
        }
        let nameBytes = Array(name.utf8)
        let offset = UInt32(output.count)
        // ローカルファイルヘッダー
        Self.put32(&output, 0x0403_4B50); Self.put16(&output, 20); Self.put16(&output, 0); Self.put16(&output, method)
        Self.put16(&output, 0); Self.put16(&output, 0x21)
        Self.put32(&output, crc); Self.put32(&output, UInt32(stored.count)); Self.put32(&output, UInt32(data.count))
        Self.put16(&output, UInt16(nameBytes.count)); Self.put16(&output, 0)
        output.append(contentsOf: nameBytes)
        output.append(contentsOf: stored)
        // 中央ディレクトリ
        Self.put32(&central, 0x0201_4B50); Self.put16(&central, 20); Self.put16(&central, 20); Self.put16(&central, 0)
        Self.put16(&central, method); Self.put16(&central, 0); Self.put16(&central, 0x21)
        Self.put32(&central, crc); Self.put32(&central, UInt32(stored.count)); Self.put32(&central, UInt32(data.count))
        Self.put16(&central, UInt16(nameBytes.count)); Self.put16(&central, 0); Self.put16(&central, 0); Self.put16(&central, 0)
        Self.put16(&central, 0); Self.put32(&central, 0); Self.put32(&central, offset)
        central.append(contentsOf: nameBytes)
        count += 1
    }

    mutating func finish() throws -> Data {
        let centralOffset = UInt32(output.count)
        output.append(contentsOf: central)
        Self.put32(&output, 0x0605_4B50); Self.put16(&output, 0); Self.put16(&output, 0)
        Self.put16(&output, UInt16(count)); Self.put16(&output, UInt16(count))
        Self.put32(&output, UInt32(central.count)); Self.put32(&output, centralOffset); Self.put16(&output, 0)
        return Data(output)
    }

    private static func put16(_ b: inout [UInt8], _ v: UInt16) { b.append(UInt8(v & 0xFF)); b.append(UInt8(v >> 8)) }
    private static func put32(_ b: inout [UInt8], _ v: UInt32) {
        b.append(UInt8(v & 0xFF)); b.append(UInt8(v >> 8 & 0xFF)); b.append(UInt8(v >> 16 & 0xFF)); b.append(UInt8(v >> 24))
    }

    /// macOSではCompressionフレームワークのDEFLATE（生のRFC1951）で圧縮する。使えない環境では無圧縮。
    static func deflate(_ data: [UInt8]) -> [UInt8]? {
        #if canImport(Compression)
        guard !data.isEmpty else { return nil }
        let capacity = data.count + data.count / 8 + 1024
        var dst = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBufferPointer { src in
            dst.withUnsafeMutableBufferPointer { out in
                compression_encode_buffer(out.baseAddress!, capacity, src.baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return Array(dst[0..<written])
        #else
        return nil
        #endif
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func checksum(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
