import Foundation

/// 1セル分の判定結果。
public struct TypedCell: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case empty, text, number, date }
    public var kind: Kind
    /// text: 元の文字列。number/date: xlsxの<v>に書く値（数値の文字列）
    public var value: String
    /// Excelの表示形式。nilは「標準」
    public var format: String?
    /// Excelに任せると勝手に変換される値なので、文字列として守ったもの
    public var isProtected: Bool
    /// 数値モードで12桁以上の整数にしたもの（CSVでは指数表示になりうる）
    public var isLongNumber: Bool = false

    static let empty = TypedCell(kind: .empty, value: "", format: nil, isProtected: false)
    static func text(_ s: String, protected: Bool) -> TypedCell {
        TypedCell(kind: .text, value: s, format: protected ? "@" : nil, isProtected: protected)
    }
}

public struct TypingOptions: Sendable, Equatable {
    /// 12桁以上の数字だけの値を文字列にする（既定）。false なら数値（指数表記にならない書式）にする。
    public var longDigitsAsText: Bool = true
    public init(longDigitsAsText: Bool = true) { self.longDigitsAsText = longDigitsAsText }
}

/// セルの値を見て、Excelでどう扱うべきかを決める。
/// 方針：はっきり数値・日付と言えるものだけ数値・日付にし、それ以外は元の文字列のまま残す。
public enum CellTyping {
    public static func classify(_ raw: String, options: TypingOptions) -> TypedCell {
        if raw.isEmpty { return .empty }
        let s = Array(trimSpaces(raw).unicodeScalars)
        if s.isEmpty { return .text(raw, protected: false) }

        if let number = number(s, options: options) { return number }
        if let date = dateTime(s) { return date }
        return .text(raw, protected: excelWouldConvert(s) || fullWidthLooksNumeric(s))
    }

    /// 全角の数字・記号を半角にしたとき数値や日付に見えるもの（CSVではExcelが「１２３」を数値123にする）
    static func fullWidthLooksNumeric(_ s: [Unicode.Scalar]) -> Bool {
        var changed = false
        let mapped = s.map { c -> Unicode.Scalar in
            if c.value >= 0xFF01 && c.value <= 0xFF5E, let half = Unicode.Scalar(c.value - 0xFEE0) { changed = true; return half }
            if c.value == 0x3000 { changed = true; return " " }
            return c
        }
        guard changed else { return false }
        let t = Array(trimSpaces(String(String.UnicodeScalarView(mapped))).unicodeScalars)
        guard t.contains(where: isDigit) else { return false }
        return numberShape(t) != nil || dateTime(t) != nil || excelWouldConvert(t)
    }

    static func trimSpaces(_ s: String) -> Substring {
        var sub = Substring(s)
        while let f = sub.unicodeScalars.first, f == " " || f == "\t" { sub = sub.dropFirst() }
        while let l = sub.unicodeScalars.last, l == " " || l == "\t" { sub = sub.dropLast() }
        return sub
    }

    static func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 48 && c.value <= 57 }

    // MARK: 数値

    struct NumberShape {
        var negative: Bool
        var integer: [Unicode.Scalar]   // カンマを除いた整数部
        var fraction: [Unicode.Scalar]? // 小数部（"."の後）
        var grouped: Bool               // 3桁区切りのカンマあり
        var percent: Bool
    }

    /// [-] 整数部 [.小数部] [%]。整数部は「数字の並び」か「1〜3桁＋(,3桁)の繰り返し」。
    static func numberShape(_ s: [Unicode.Scalar]) -> NumberShape? {
        var i = 0
        var negative = false
        if i < s.count && s[i] == "-" { negative = true; i += 1 }
        var integer: [Unicode.Scalar] = []
        var groupLengths: [Int] = []
        var run = 0
        while i < s.count {
            let c = s[i]
            if isDigit(c) { integer.append(c); run += 1; i += 1 }
            else if c == "," { groupLengths.append(run); run = 0; i += 1 }
            else { break }
        }
        groupLengths.append(run)
        guard !integer.isEmpty else { return nil }
        let grouped = groupLengths.count > 1
        if grouped {
            guard (1...3).contains(groupLengths[0]), groupLengths.dropFirst().allSatisfy({ $0 == 3 }) else { return nil }
        }
        var fraction: [Unicode.Scalar]? = nil
        if i < s.count && s[i] == "." {
            i += 1
            var f: [Unicode.Scalar] = []
            while i < s.count && isDigit(s[i]) { f.append(s[i]); i += 1 }
            guard !f.isEmpty else { return nil }
            fraction = f
        }
        var percent = false
        if i < s.count && s[i] == "%" { percent = true; i += 1 }
        guard i == s.count else { return nil }
        return NumberShape(negative: negative, integer: integer, fraction: fraction, grouped: grouped, percent: percent)
    }

    static func number(_ s: [Unicode.Scalar], options: TypingOptions) -> TypedCell? {
        guard let n = numberShape(s) else { return nil }
        let original = String(String.UnicodeScalarView(s))
        // 先頭ゼロ（00123 など）は番号として文字列で守る。グループ区切りでも同じ。
        if n.integer.count >= 2 && n.integer[0] == "0" {
            return .text(original, protected: true)
        }
        // 有効桁が15桁を超える値は、Excelの数値にすると末尾が0に化ける
        var digits = n.integer + (n.fraction ?? [])
        while let f = digits.first, f == "0" { digits.removeFirst() }
        while let l = digits.last, l == "0" { digits.removeLast() }
        if digits.count > 15 { return .text(original, protected: true) }

        let plainInteger = n.fraction == nil && !n.grouped && !n.percent
        var longNumber = false
        if plainInteger && n.integer.count >= 12 {
            if !n.negative && options.longDigitsAsText { return .text(original, protected: true) }
            longNumber = true
        }

        let intString = String(String.UnicodeScalarView(n.integer))
        let fracString = n.fraction.map { String(String.UnicodeScalarView($0)) }
        var value: String
        if n.percent {
            value = shiftDecimal(integer: intString, fraction: fracString ?? "", by: 2)
        } else {
            value = intString + (fracString.map { "." + $0 } ?? "")
        }
        if n.negative && value.contains(where: { $0 != "0" && $0 != "." }) { value = "-" + value }

        let fractionDigits = n.fraction?.count ?? 0
        var format: String? = nil
        let decimals = fractionDigits > 0 ? "." + String(repeating: "0", count: fractionDigits) : ""
        if n.percent {
            format = (n.grouped ? "#,##0" : "0") + decimals + "%"
        } else if n.grouped {
            format = "#,##0" + decimals
        } else if fractionDigits > 0 {
            format = "0" + decimals
        } else if longNumber {
            format = "0"
        }
        var cell = TypedCell(kind: .number, value: value, format: format, isProtected: false)
        cell.isLongNumber = longNumber
        return cell
    }

    /// 小数点を左に places 桁ずらした値（12.5% → 0.125）。浮動小数点を使わず文字列で計算する。
    static func shiftDecimal(integer: String, fraction: String, by places: Int) -> String {
        let all = Array(integer + fraction)
        let point = integer.count - places
        var intPart: [Character]
        var fracPart: [Character]
        if point <= 0 {
            intPart = ["0"]
            fracPart = Array(repeating: "0", count: -point) + all
        } else {
            intPart = Array(all[0..<point])
            fracPart = Array(all[point...])
        }
        while intPart.count > 1 && intPart.first == "0" { intPart.removeFirst() }
        while fracPart.last == "0" { fracPart.removeLast() }
        return String(intPart) + (fracPart.isEmpty ? "" : "." + String(fracPart))
    }

    // MARK: 日付・時刻

    struct DateParts { var year: Int; var month: Int; var day: Int; var format: String }
    struct TimeParts { var hour: Int; var minute: Int; var second: Int; var format: String }

    static func dateTime(_ s: [Unicode.Scalar]) -> TypedCell? {
        if let space = s.firstIndex(of: " ") {
            guard let date = dateParts(Array(s[..<space])),
                  let time = timeParts(Array(s[(space + 1)...]), allowOver24: false) else { return nil }
            guard let serial = serialDay(date) else { return nil }
            let value = decimalString(Double(serial) + Double(time.hour * 3600 + time.minute * 60 + time.second) / 86_400)
            return TypedCell(kind: .date, value: value, format: date.format + " " + time.format, isProtected: false)
        }
        if let date = dateParts(s) {
            guard let serial = serialDay(date) else { return nil }
            return TypedCell(kind: .date, value: String(serial), format: date.format, isProtected: false)
        }
        if let time = timeParts(s, allowOver24: true) {
            let value = decimalString(Double(time.hour * 3600 + time.minute * 60 + time.second) / 86_400)
            return TypedCell(kind: .date, value: value, format: time.format, isProtected: false)
        }
        return nil
    }

    static func digitsValue(_ s: ArraySlice<Unicode.Scalar>) -> Int? {
        guard !s.isEmpty, s.count <= 9, s.allSatisfy(isDigit) else { return nil }
        return s.reduce(0) { $0 * 10 + Int($1.value - 48) }
    }

    /// 2026/10/20、2026-1-5、2026年10月20日。年は4桁必須。
    static func dateParts(_ s: [Unicode.Scalar]) -> DateParts? {
        var pieces: [ArraySlice<Unicode.Scalar>] = []
        var separators: [Unicode.Scalar] = []
        var start = 0
        for (i, c) in s.enumerated() where !isDigit(c) {
            pieces.append(s[start..<i]); separators.append(c); start = i + 1
        }
        pieces.append(s[start...])
        let ymd: (String, String, String)
        if separators == ["/", "/"] || separators == ["-", "-"] {
            guard pieces.count == 3 else { return nil }
            let sep = String(separators[0])
            ymd = (sep, sep, "")
        } else if separators == ["年", "月", "日"] {
            guard pieces.count == 4, pieces[3].isEmpty else { return nil }
            pieces.removeLast()
            ymd = ("\"年\"", "\"月\"", "\"日\"")
        } else {
            return nil
        }
        guard pieces[0].count == 4, (1...2).contains(pieces[1].count), (1...2).contains(pieces[2].count),
              let y = digitsValue(pieces[0]), let m = digitsValue(pieces[1]), let d = digitsValue(pieces[2]),
              (1...12).contains(m), d >= 1, d <= daysInMonth(y, m) else { return nil }
        let mm = pieces[1].count == 2 && pieces[1].first == "0" ? "mm" : "m"
        let dd = pieces[2].count == 2 && pieces[2].first == "0" ? "dd" : "d"
        return DateParts(year: y, month: m, day: d, format: "yyyy" + ymd.0 + mm + ymd.1 + dd + ymd.2)
    }

    /// 8:05、08:05、23:59:59。allowOver24 のときは 37:30 のような時間の長さも許す。
    static func timeParts(_ s: [Unicode.Scalar], allowOver24: Bool) -> TimeParts? {
        let pieces = s.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2 || pieces.count == 3,
              (1...2).contains(pieces[0].count), pieces.dropFirst().allSatisfy({ $0.count == 2 }),
              let h = digitsValue(pieces[0]), let m = digitsValue(pieces[1]), m <= 59 else { return nil }
        let sec = pieces.count == 3 ? digitsValue(pieces[2]) : 0
        guard let sec, sec <= 59 else { return nil }
        if h > 23 && !allowOver24 { return nil }
        let hourFormat = h > 23 ? "[h]" : (pieces[0].count == 2 && pieces[0].first == "0" ? "hh" : "h")
        return TimeParts(hour: h, minute: m, second: sec, format: hourFormat + ":mm" + (pieces.count == 3 ? ":ss" : ""))
    }

    static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        switch m {
        case 2: return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Excelのシリアル値（1900年3月1日以降のみ。それより前はExcelの日付にしない）
    static func serialDay(_ d: DateParts) -> Int? {
        guard d.year >= 1900, d.year <= 9999, !(d.year == 1900 && d.month < 3) else { return nil }
        return daysFromCivil(d.year, d.month, d.day) - daysFromCivil(1899, 12, 30)
    }

    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func decimalString(_ v: Double) -> String {
        var s = String(format: "%.10f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    // MARK: Excelが勝手に変換しそうな文字列

    /// 文字列として残す値のうち、CSVのままExcelで開くと数値・日付・数式に変わってしまうもの。
    /// CSV出力のときは先頭に「'」を付け、xlsx出力のときは表示形式を「文字列」にする。
    static func excelWouldConvert(_ s: [Unicode.Scalar]) -> Bool {
        guard let first = s.first else { return false }
        // 数式とみなされる書き出し
        if first == "=" || first == "@" { return true }
        if (first == "+" || first == "-") && s.count >= 2 { return true }
        // 数字で始まり、数字と一部の記号だけでできているもの（指数表記・日付・時刻・分数など）
        let allowed: Set<Unicode.Scalar> = ["/", "-", ":", ".", "e", "E", "+", ",", "%", "年", "月", "日"]
        if isDigit(first) && s.contains(where: { !isDigit($0) }) == true {
            if s.allSatisfy({ isDigit($0) || allowed.contains($0) }) { return true }
        }
        return false
    }
}
