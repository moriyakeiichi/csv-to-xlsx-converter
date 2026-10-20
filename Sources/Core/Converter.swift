import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum OutputFormat: String, CaseIterable, Sendable {
    case xlsx, csv
    public var label: String {
        switch self {
        case .xlsx: return "Excelブック（.xlsx）"
        case .csv: return "CSV（UTF-8・BOM付き）"
        }
    }
}

public struct ConversionOptions: Sendable, Equatable {
    public var format: OutputFormat = .xlsx
    public var typing = TypingOptions()
    public var encoding: SourceEncoding = .auto
    public var delimiter: DelimiterChoice = .auto
    public init(format: OutputFormat = .xlsx, typing: TypingOptions = TypingOptions(),
                encoding: SourceEncoding = .auto, delimiter: DelimiterChoice = .auto) {
        self.format = format; self.typing = typing; self.encoding = encoding; self.delimiter = delimiter
    }
}

public struct ConversionReport: Sendable {
    public let input: URL
    public let output: URL
    /// 同じ内容の出力がすでにあったので、それを使った
    public let reusedExisting: Bool
    public let encodingName: String
    public let delimiterName: String
    public let rowCount: Int
    public let columnCount: Int
    public let counts: CellCounts
    public let warnings: [String]
}

public struct Converter: Sendable {
    public static let acceptedExtensions: Set<String> = ["csv", "tsv", "txt"]
    let decoder: TextDecoder
    /// 元のフォルダに書けないときの保存先
    let fallbackDirectory: URL?

    public init(tables: LegacyTables, fallbackDirectory: URL?) {
        decoder = TextDecoder(tables: tables)
        self.fallbackDirectory = fallbackDirectory
    }

    public func convert(_ input: URL, options: ConversionOptions) throws -> ConversionReport {
        let resolved = input.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
            throw ConversionError("ファイルが見つかりません。")
        }
        guard !isDirectory.boolValue else { throw ConversionError("フォルダは変換できません。") }
        let data: Data
        do { data = try Data(contentsOf: resolved) }
        catch { throw ConversionError("ファイルを読み込めません（\(error.localizedDescription)）。") }

        let decoded = decoder.decode(data, as: options.encoding)
        var warnings = decoded.warnings
        let delimiter = options.delimiter.scalar ?? Delimited.detectDelimiter(decoded.text)
        let rows = Delimited.parse(decoded.text, delimiter: delimiter)
        let stem = input.deletingPathExtension().lastPathComponent

        let bytes: Data
        let counts: CellCounts
        let ext: String
        switch options.format {
        case .xlsx:
            let result = try XLSXWriter.make(rows: rows, sheetName: stem, options: options.typing)
            bytes = result.data
            counts = result.counts
            warnings += result.warnings
            ext = "xlsx"
        case .csv:
            var c = CellCounts()
            let out = rows.map { row in
                row.map { raw -> String in
                    let cell = CellTyping.classify(raw, options: options.typing)
                    c.add(cell)
                    return cell.isProtected ? "'" + raw : raw
                }
            }
            if c.longNumbers > 0 {
                warnings.append("12桁以上の数字\(c.longNumbers)セルを数値のままにしました。CSVではExcelが指数表記（例：4.90123E+12）で表示することがあります。桁をすべて表示したい場合は、出力形式をExcelブック（.xlsx）にしてください。")
            }
            bytes = Delimited.encodeCSV(out)
            counts = c
            ext = "csv"
        }

        let directory = input.deletingLastPathComponent()
        let saved: (url: URL, reused: Bool)
        do {
            saved = try save(bytes, directory: directory, stem: stem, ext: ext)
        } catch let error as WriteDenied {
            guard let fallback = fallbackDirectory else { throw ConversionError(error.message) }
            try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            do { saved = try save(bytes, directory: fallback, stem: stem, ext: ext) }
            catch let second as WriteDenied { throw ConversionError(second.message) }
            warnings.append("元のファイルと同じフォルダに保存できなかったため、「\(fallback.path)」に保存しました。")
        }

        return ConversionReport(input: input, output: saved.url, reusedExisting: saved.reused,
                                encodingName: decoded.encodingName, delimiterName: Delimited.name(of: delimiter),
                                rowCount: rows.count, columnCount: rows.map(\.count).max() ?? 0,
                                counts: counts, warnings: warnings)
    }

    struct WriteDenied: Error { let message: String }

    /// 「名前_excel.xlsx」に保存する。すでに同名があれば、中身が同じならそれを使い、違えば「名前_excel 2.xlsx」…と番号を付ける。
    /// 既存のファイルは決して上書きしない。
    func save(_ data: Data, directory: URL, stem: String, ext: String) throws -> (url: URL, reused: Bool) {
        for n in 1...999 {
            let name = n == 1 ? "\(stem)_excel.\(ext)" : "\(stem)_excel \(n).\(ext)"
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                if let existing = try? Data(contentsOf: url), existing == data { return (url, true) }
                continue
            }
            switch writeExclusively(data, to: url) {
            case .success: return (url, false)
            case .exists: continue
            case .denied(let reason): throw WriteDenied(message: "保存できません：\(directory.path)（\(reason)）")
            case .failed(let reason): throw ConversionError("保存に失敗しました：\(name)（\(reason)）")
            }
        }
        throw ConversionError("同じ名前の出力が多すぎます（999件）。古い出力を整理してください。")
    }

    enum WriteOutcome { case success, exists, denied(String), failed(String) }

    /// O_EXCLで新規作成だけを行う（既存ファイルは上書きしない）。途中で失敗したら作りかけを消す。
    func writeExclusively(_ data: Data, to url: URL) -> WriteOutcome {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        if fd < 0 {
            let code = errno
            let reason = String(cString: strerror(code))
            if code == EEXIST { return .exists }
            if code == EACCES || code == EPERM || code == EROFS { return .denied(reason) }
            return .failed(reason)
        }
        var ok = true
        var reason = ""
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    ok = false; reason = String(cString: strerror(errno)); return
                }
                offset += n
            }
        }
        if ok && fsync(fd) != 0 { ok = false; reason = String(cString: strerror(errno)) }
        if close(fd) != 0 && ok { ok = false; reason = String(cString: strerror(errno)) }
        if !ok {
            unlink(url.path)
            return .failed(reason)
        }
        return .success
    }
}
