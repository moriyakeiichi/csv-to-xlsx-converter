// 変換エンジンのテスト。macOS（build.sh）とLinux（開発時）の両方で実行できる。
// 使い方: CoreTests <フォルダのルート> <作業用フォルダ>
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

var passed = 0
var failures: [String] = []
func check(_ ok: Bool, _ message: @autoclosure () -> String) {
    if ok { passed += 1 } else { failures.append(message()) }
}

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let work = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.removeItem(at: work)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
let tables = try LegacyTables(directory: root.appendingPathComponent("Resources"))
let decoder = TextDecoder(tables: tables)

// MARK: 文字コード
let fixtures = root.appendingPathComponent("Tests/Fixtures")
let decodeCases: [(String, String)] = [
    ("utf8_bom", "UTF-8（BOM付き）"), ("utf8", "UTF-8"), ("cp932", "Shift_JIS（CP932）"), ("eucjp", "EUC-JP"),
    ("utf16le_bom_tab", "UTF-16LE（BOM付き）"), ("utf16be_bom", "UTF-16BE（BOM付き）"), ("utf16le_nobom", "UTF-16LE（BOMなし）"),
    ("bom_plus_sjis", "Shift_JIS（CP932）（先頭にUTF-8のBOMあり）"), ("halfkana_sjis", "Shift_JIS（CP932）"),
    ("semicolon", "UTF-8"), ("broken", "Shift_JIS（CP932）（読めない文字を置換）"),
]
for (name, encoding) in decodeCases {
    let data = try Data(contentsOf: fixtures.appendingPathComponent(name + ".bin"))
    let expected = try String(contentsOf: fixtures.appendingPathComponent(name + ".expected.txt"), encoding: .utf8)
    let decoded = decoder.decode(data, as: .auto)
    check(decoded.text == expected, "decode text \(name): \(decoded.encodingName)")
    check(decoded.encodingName == encoding, "decode name \(name): got \(decoded.encodingName)")
    let warned = !decoded.warnings.isEmpty
    let shouldWarn = name == "broken" || name == "bom_plus_sjis"
    check(warned == shouldWarn, "decode warning \(name): \(decoded.warnings)")
}
// 指定した文字コードで読む
do {
    let data = try Data(contentsOf: fixtures.appendingPathComponent("eucjp.bin"))
    let forced = decoder.decode(data, as: .cp932)
    check(forced.encodingName.contains("指定"), "forced name")
    let euc = decoder.decode(data, as: .eucJP)
    check(euc.text == (try String(contentsOf: fixtures.appendingPathComponent("eucjp.expected.txt"), encoding: .utf8)), "forced euc")
    check(euc.warnings.isEmpty, "forced euc no warning")
}

// MARK: 区切り文字
check(Delimited.detectDelimiter("a,b,c\n1,2,3\n") == ",", "detect comma")
check(Delimited.detectDelimiter("a\tb\tc\n1\t2\t3\n") == "\t", "detect tab")
check(Delimited.detectDelimiter("a;b;c\n1;2;3\n") == ";", "detect semicolon")
check(Delimited.detectDelimiter("\"東京都,新宿区\"\t1\n\"a,b,c\"\t2\n") == "\t", "detect tab with quoted commas")
check(Delimited.detectDelimiter("ひとつだけ\n二行目\n") == ",", "detect single column")
check(Delimited.detectDelimiter("名前,説明\nA,\"x;y;z\"\nB,\"p;q;r\"\n") == ",", "detect comma over quoted semicolons")

// MARK: CSVの読み取り
check(Delimited.parse("a,b\r\nc,d", delimiter: ",") == [["a", "b"], ["c", "d"]], "parse basic")
check(Delimited.parse("\"a,b\",\"q\"\"r\"\n", delimiter: ",") == [["a,b", "q\"r"]], "parse quotes")
check(Delimited.parse("\"line1\r\nline2\",x\n", delimiter: ",") == [["line1\r\nline2", "x"]], "parse embedded newline")
check(Delimited.parse("a\n\nb\n", delimiter: ",") == [["a"], [], ["b"]], "parse blank line")
check(Delimited.parse("a,\n", delimiter: ",") == [["a", ""]], "parse trailing empty")
check(Delimited.parse("\"open", delimiter: ",") == [["open"]], "parse unterminated")
check(Delimited.parse("a\rb\r", delimiter: ",") == [["a"], ["b"]], "parse CR only")

// MARK: セルの判定
struct Expect { let raw: String; let kind: TypedCell.Kind; let value: String?; let format: String?; let protected: Bool }
func E(_ raw: String, _ kind: TypedCell.Kind, _ value: String? = nil, _ format: String? = nil, protected: Bool = false) -> Expect {
    Expect(raw: raw, kind: kind, value: value, format: format, protected: protected)
}
let textOpt = TypingOptions(longDigitsAsText: true)
let numOpt = TypingOptions(longDigitsAsText: false)
let cellCases: [(Expect, TypingOptions)] = [
    (E("", .empty), textOpt),
    (E("   ", .text, "   "), textOpt),
    (E("123", .number, "123"), textOpt),
    (E("0", .number, "0"), textOpt),
    (E("-42", .number, "-42"), textOpt),
    (E("-1.25", .number, "-1.25", "0.00"), textOpt),
    (E("12.50", .number, "12.50", "0.00"), textOpt),
    (E("1,234,567", .number, "1234567", "#,##0"), textOpt),
    (E("-1,234.5", .number, "-1234.5", "#,##0.0"), textOpt),
    (E("12.5%", .number, "0.125", "0.0%"), textOpt),
    (E("3%", .number, "0.03", "0%"), textOpt),
    (E("0.5", .number, "0.5", "0.0"), textOpt),
    (E(" 123 ", .number, "123"), textOpt),
    (E("00123", .text, "00123", "@", protected: true), textOpt),
    (E("0.5.1", .text, "0.5.1", "@", protected: true), textOpt),
    (E("12345678901", .number, "12345678901"), textOpt),
    (E("123456789012", .text, "123456789012", "@", protected: true), textOpt),
    (E("4901234567894", .text, "4901234567894", "@", protected: true), textOpt),
    (E("4901234567894", .number, "4901234567894", "0"), numOpt),
    (E("123456789012345", .number, "123456789012345", "0"), numOpt),
    (E("1234567890123456", .text, "1234567890123456", "@", protected: true), numOpt),
    (E("-123456789012", .number, "-123456789012", "0"), textOpt),
    (E("123,456,789,012", .number, "123456789012", "#,##0"), textOpt),
    (E("1,23", .text, "1,23", "@", protected: true), textOpt),
    (E("+81312345678", .text, "+81312345678", "@", protected: true), textOpt),
    (E("+7", .text, "+7", "@", protected: true), textOpt),
    (E("1E3", .text, "1E3", "@", protected: true), textOpt),
    (E("1.2e-03", .text, "1.2e-03", "@", protected: true), textOpt),
    (E("2026/10/20", .date, "46315", "yyyy/m/d"), textOpt),
    (E("2026/01/05", .date, "46027", "yyyy/mm/dd"), textOpt),
    (E("2026-10-20", .date, "46315", "yyyy-m-d"), textOpt),
    (E("2026年10月20日", .date, "46315", "yyyy\"年\"m\"月\"d\"日\""), textOpt),
    (E("2026-10-20 12:34", .date, "46315.5236111111", "yyyy-m-d h:mm"), textOpt),
    (E("2026/10/20 08:05:30", .date, "46315.3371527778", "yyyy/m/d hh:mm:ss"), textOpt),
    (E("2000/2/29", .date, "36585", "yyyy/m/d"), textOpt),
    (E("2026/2/29", .text, "2026/2/29", "@", protected: true), textOpt),
    (E("1899/12/31", .text, "1899/12/31", "@", protected: true), textOpt),
    (E("10/20", .text, "10/20", "@", protected: true), textOpt),
    (E("1-2", .text, "1-2", "@", protected: true), textOpt),
    (E("1-2-3", .text, "1-2-3", "@", protected: true), textOpt),
    (E("2026/10", .text, "2026/10", "@", protected: true), textOpt),
    (E("10月20日", .text, "10月20日", "@", protected: true), textOpt),
    (E("08:05", .date, "0.3368055556", "hh:mm"), textOpt),
    (E("8:05", .date, "0.3368055556", "h:mm"), textOpt),
    (E("23:59:59", .date, "0.9999884259", "h:mm:ss"), textOpt),
    (E("37:30", .date, "1.5625", "[h]:mm"), textOpt),
    (E("24:99", .text, "24:99", "@", protected: true), textOpt),
    (E("=1+1", .text, "=1+1", "@", protected: true), textOpt),
    (E("@SUM(A1)", .text, "@SUM(A1)", "@", protected: true), textOpt),
    (E("-abc", .text, "-abc", "@", protected: true), textOpt),
    (E("-", .text, "-"), textOpt),
    (E("りんご", .text, "りんご"), textOpt),
    (E("001A", .text, "001A"), textOpt),
    (E("０１２３", .text, "０１２３", "@", protected: true), textOpt),
    (E("１２３", .text, "１２３", "@", protected: true), textOpt),
    (E("－１，２３４", .text, "－１，２３４", "@", protected: true), textOpt),
    (E("２０２６／１０／２０", .text, "２０２６／１０／２０", "@", protected: true), textOpt),
    (E("－あ", .text, "－あ"), textOpt),
    (E("ＡＢＣ", .text, "ＡＢＣ"), textOpt),
    (E("ｶﾀｶﾅ", .text, "ｶﾀｶﾅ"), textOpt),
    (E("'00123", .text, "'00123"), textOpt),
    (E("-0", .number, "0"), textOpt),
    (E("-00", .text, "-00", "@", protected: true), textOpt),
]
for (e, opt) in cellCases {
    let c = CellTyping.classify(e.raw, options: opt)
    let ok = c.kind == e.kind && (e.value == nil || c.value == e.value!) && c.format == e.format && c.isProtected == e.protected
    check(ok, "cell \(e.raw.debugDescription) opt=\(opt.longDigitsAsText): got kind=\(c.kind) value=\(c.value) format=\(c.format ?? "nil") protected=\(c.isProtected)")
}
check(CellTyping.shiftDecimal(integer: "1234", fraction: "5", by: 2) == "12.345", "shift 1")
check(CellTyping.shiftDecimal(integer: "0", fraction: "", by: 2) == "0", "shift 0")
check(XLSXWriter.columnName(0) == "A" && XLSXWriter.columnName(25) == "Z" && XLSXWriter.columnName(26) == "AA" && XLSXWriter.columnName(16383) == "XFD", "column names")
check(XLSXWriter.safeSheetName("a/b:c?[d]") == "a_b_c__d_", "sheet name")
check(XLSXWriter.safeSheetName(String(repeating: "あ", count: 40)).count == 31, "sheet name length")
check(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926, "crc32")

// MARK: 変換とファイル保存
let converter = Converter(tables: tables, fallbackDirectory: work.appendingPathComponent("fallback"))
let samples = work.appendingPathComponent("samples")
try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
for (name, _) in decodeCases {
    let source = samples.appendingPathComponent(name + ".csv")
    try Data(contentsOf: fixtures.appendingPathComponent(name + ".bin")).write(to: source)
}
let cp = samples.appendingPathComponent("cp932.csv")
let original = try Data(contentsOf: cp)
let first = try converter.convert(cp, options: ConversionOptions())
check(first.output.lastPathComponent == "cp932_excel.xlsx" && !first.reusedExisting, "first output name")
check(try Data(contentsOf: cp) == original, "input unchanged")
let again = try converter.convert(cp, options: ConversionOptions())
check(again.output == first.output && again.reusedExisting, "same content reused")
let numberMode = try converter.convert(cp, options: ConversionOptions(typing: TypingOptions(longDigitsAsText: false)))
check(numberMode.output.lastPathComponent == "cp932_excel 2.xlsx" && !numberMode.reusedExisting, "different content numbered")
// 既存ファイルを書き換えた場合は上書きせず別名
try Data("edited".utf8).write(to: first.output)
let third = try converter.convert(cp, options: ConversionOptions())
check(third.output.lastPathComponent == "cp932_excel 3.xlsx", "edited existing never overwritten: \(third.output.lastPathComponent)")
check(try Data(contentsOf: first.output) == Data("edited".utf8), "edited file preserved")
let csvOut = try converter.convert(cp, options: ConversionOptions(format: .csv))
check(csvOut.output.lastPathComponent == "cp932_excel.csv", "csv output name")
let csvText = String(decoding: try Data(contentsOf: csvOut.output).dropFirst(3), as: UTF8.self)
check(csvText.hasPrefix("日付,会員番号,JANコード,金額,割合,メモ\r\n2026/10/20,'00123,'4901234567894,-1500,12.5%,\"東京都,新宿区\"\r\n"), "csv content: \(csvText.prefix(120))")
check(csvText.contains("'10/20,'1-2,'1234567890123456,-1.25,0.5,'=1+1\r\n"), "csv protect line")
check(csvText.contains("2026年10月20日,'+81312345678,'1E3,12.50,08:05,ｶﾀｶﾅ"), "csv line 5")
let csvNum = try converter.convert(cp, options: ConversionOptions(format: .csv, typing: TypingOptions(longDigitsAsText: false)))
check(csvNum.warnings.contains { $0.contains("指数表記") }, "csv long number warning")

// 書き込めないフォルダ（rootでは権限が効かないので省略）
if geteuid() != 0 {
    let locked = work.appendingPathComponent("locked")
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    let lockedInput = locked.appendingPathComponent("in.csv")
    try Data("001,2\n".utf8).write(to: lockedInput)
    chmod(locked.path, 0o500)
    let r = try converter.convert(lockedInput, options: ConversionOptions())
    chmod(locked.path, 0o700)
    check(r.output.deletingLastPathComponent().lastPathComponent == "fallback" && r.warnings.contains { $0.contains("保存できなかった") }, "fallback directory")
}
do {
    _ = try converter.convert(work.appendingPathComponent("missing.csv"), options: ConversionOptions())
    check(false, "missing should throw")
} catch { check(true, "") }

// 検証用に全サンプルをxlsxへ
let outputs = work.appendingPathComponent("outputs")
try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
for (name, _) in decodeCases {
    let src = outputs.appendingPathComponent(name + ".csv")
    try Data(contentsOf: fixtures.appendingPathComponent(name + ".bin")).write(to: src)
    let r = try converter.convert(src, options: ConversionOptions())
    print("\(name): \(r.encodingName) / \(r.delimiterName) / \(r.rowCount)行 / 数値\(r.counts.numbers) 日付\(r.counts.dates) 文字列\(r.counts.texts)（保護\(r.counts.protected)）")
}
// 大きめのデータ（速度とメモリの目安）
var big = "id,code,amount,date,memo\r\n"
for i in 0..<100_000 { big += "\(i),\(String(format: "%013d", i)),\(-i * 3),2026/10/\(i % 28 + 1),メモ\(i)\r\n" }
let bigURL = outputs.appendingPathComponent("big.csv")
try Data(big.utf8).write(to: bigURL)
let started = Date()
let bigReport = try converter.convert(bigURL, options: ConversionOptions())
let elapsed = Date().timeIntervalSince(started)
let bigSize = (try FileManager.default.attributesOfItem(atPath: bigReport.output.path)[.size] as? Int) ?? 0
print(String(format: "big: 100000行 %.2f秒, %d bytes", elapsed, bigSize))
check(bigReport.rowCount == 100_001, "big rows")

print("PASS \(passed) / FAIL \(failures.count)")
for f in failures { print("FAIL: " + f) }
exit(failures.isEmpty ? 0 : 1)
