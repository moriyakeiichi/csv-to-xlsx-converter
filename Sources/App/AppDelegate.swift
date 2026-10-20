import AppKit
import UniformTypeIdentifiers

// MARK: - ドロップ領域

final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?
    private var highlighted = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = 12
        layer.borderWidth = highlighted ? 3 : 1.5
        layer.borderColor = (highlighted ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer.backgroundColor = (highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.10)
                                             : NSColor.controlBackgroundColor).cgColor
    }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true]) ?? []
        return objects.compactMap { $0 as? URL }
    }
    private func acceptable(_ urls: [URL]) -> Bool {
        urls.contains { Converter.acceptedExtensions.contains($0.pathExtension.lowercased()) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = onDrop != nil && acceptable(fileURLs(sender))
        return highlighted ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { highlighted }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        let urls = fileURLs(sender)
        guard acceptable(urls), let onDrop else { return false }
        onDrop(urls)
        return true
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { highlighted = false }
}

// MARK: - 設定

enum Settings {
    static let defaults = UserDefaults.standard
    static var format: OutputFormat {
        get { OutputFormat(rawValue: defaults.string(forKey: "format") ?? "") ?? .xlsx }
        set { defaults.set(newValue.rawValue, forKey: "format") }
    }
    static var longDigitsAsText: Bool {
        get { defaults.object(forKey: "longDigitsAsText") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "longDigitsAsText") }
    }
    static var encoding: SourceEncoding {
        get { SourceEncoding(rawValue: defaults.string(forKey: "encoding") ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: "encoding") }
    }
    static var delimiter: DelimiterChoice {
        get { DelimiterChoice(rawValue: defaults.string(forKey: "delimiter") ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: "delimiter") }
    }
    static var openInExcel: Bool {
        get { defaults.object(forKey: "openInExcel") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "openInExcel") }
    }
}

// MARK: - アプリ本体

struct ItemResult {
    let input: URL
    let report: ConversionReport?
    let error: String?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var selectButton: NSButton!
    private var formatPopup: NSPopUpButton!
    private var digitsPopup: NSPopUpButton!
    private var encodingPopup: NSPopUpButton!
    private var delimiterPopup: NSPopUpButton!
    private var openCheckbox: NSButton!
    private var statusLabel: NSTextField!
    private var spinner: NSProgressIndicator!
    private var logView: NSTextView!

    private var converter: Converter?
    private var pending: [[URL]] = []
    private var busy = false
    private var ready = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        do {
            guard let resources = Bundle.main.resourceURL else { throw ConversionError("アプリのリソースが見つかりません。") }
            let tables = try LegacyTables(directory: resources)
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            converter = Converter(tables: tables, fallbackDirectory: downloads?.appendingPathComponent("CSV to XLSX Converter"))
        } catch {
            selectButton.isEnabled = false
            statusLabel.stringValue = error.localizedDescription
            let alert = NSAlert()
            alert.messageText = "アプリを開始できません"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
            return
        }
        ready = true
        runNext()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        enqueue(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: メニュー

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "CSV to XLSX Converterについて", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "CSV to XLSX Converterを隠す", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "CSV to XLSX Converterを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "ファイル")
        fileMenu.addItem(withTitle: "ファイルを選択…", action: #selector(chooseFiles), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "ウインドウを閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "編集")
        editMenu.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "結果欄を消去", action: #selector(clearLog), keyEquivalent: "")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "ウインドウ")
        windowMenu.addItem(withTitle: "しまう", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApplication.shared.windowsMenu = windowMenu

        NSApplication.shared.mainMenu = main
    }

    // MARK: ウインドウ

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        if secondary { field.textColor = .secondaryLabelColor }
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func popup(_ titles: [String], selected: Int) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.addItems(withTitles: titles)
        button.selectItem(at: selected)
        button.target = self
        button.action = #selector(settingsChanged)
        return button
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 700),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "CSV to XLSX Converter"
        window.minSize = NSSize(width: 560, height: 620)
        window.isReleasedWhenClosed = false
        window.center()
        _ = window.setFrameAutosaveName("MainWindow")

        let title = label("CSVを、そのままの値でExcelに", size: 22, weight: .semibold)
        let subtitle = label("文字化けさせず、先頭のゼロや長い番号、「1-2」のような値をExcelに勝手に変換させません。元のファイルは変更しません。",
                             size: 12.5, secondary: true)

        // ドロップ領域
        let drop = DropView(frame: .zero)
        drop.translatesAutoresizingMaskIntoConstraints = false
        drop.onDrop = { [weak self] urls in self?.enqueue(urls) }
        drop.setAccessibilityLabel("CSVファイルのドロップ領域")
        let dropTitle = label("ここにCSVファイルをドロップ", size: 17, weight: .medium)
        dropTitle.alignment = .center
        let dropDetail = label("複数ファイル可 · .csv / .tsv / .txt", size: 12, secondary: true)
        dropDetail.alignment = .center
        selectButton = NSButton(title: "ファイルを選択…", target: self, action: #selector(chooseFiles))
        selectButton.bezelStyle = .rounded
        selectButton.controlSize = .large
        let dropStack = NSStackView(views: [dropTitle, dropDetail, selectButton])
        dropStack.orientation = .vertical
        dropStack.alignment = .centerX
        dropStack.spacing = 8
        dropStack.translatesAutoresizingMaskIntoConstraints = false
        drop.addSubview(dropStack)

        // 設定
        formatPopup = popup(OutputFormat.allCases.map { $0 == .xlsx ? $0.label + "（推奨）" : $0.label },
                            selected: OutputFormat.allCases.firstIndex(of: Settings.format) ?? 0)
        digitsPopup = popup(["文字列として扱う（桁をそのまま表示）", "数値として扱う"], selected: Settings.longDigitsAsText ? 0 : 1)
        encodingPopup = popup(SourceEncoding.allCases.map(\.label),
                              selected: SourceEncoding.allCases.firstIndex(of: Settings.encoding) ?? 0)
        delimiterPopup = popup(DelimiterChoice.allCases.map(\.label),
                               selected: DelimiterChoice.allCases.firstIndex(of: Settings.delimiter) ?? 0)
        openCheckbox = NSButton(checkboxWithTitle: "変換したらExcelで開く", target: self, action: #selector(settingsChanged))
        openCheckbox.state = Settings.openInExcel ? .on : .off

        func rowLabel(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.alignment = .right
            return field
        }
        let grid = NSGridView(views: [
            [rowLabel("出力形式："), formatPopup],
            [rowLabel("12桁以上の数字："), digitsPopup],
            [rowLabel("文字コード："), encodingPopup],
            [rowLabel("区切り文字："), delimiterPopup],
            [NSGridCell.emptyContentView, openCheckbox],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        // 状態と結果欄
        statusLabel = label("CSVファイルを選んでください。", size: 13, weight: .medium)
        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSTextView.scrollableTextView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .bezelBorder
        logView = scroll.documentView as? NSTextView
        logView.isEditable = false
        logView.isSelectable = true
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textContainerInset = NSSize(width: 6, height: 6)
        logView.setAccessibilityLabel("変換結果")

        let footer = label("出力は元のファイルと同じフォルダに「元の名前_excel.xlsx」（CSVなら「_excel.csv」）として保存します。同じ内容の出力があればそれを開き、内容が違えば番号を付けて別に保存します。既存のファイルは上書きしません。",
                           size: 11, secondary: true)

        let content = NSView()
        window.contentView = content
        for view in [title, subtitle, drop, grid, statusLabel!, spinner!, scroll, footer] as [NSView] {
            content.addSubview(view)
        }
        let margin: CGFloat = 24
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            drop.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16),
            drop.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            drop.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            drop.heightAnchor.constraint(equalToConstant: 140),
            dropStack.centerXAnchor.constraint(equalTo: drop.centerXAnchor),
            dropStack.centerYAnchor.constraint(equalTo: drop.centerYAnchor),
            dropStack.leadingAnchor.constraint(greaterThanOrEqualTo: drop.leadingAnchor, constant: 12),

            grid.topAnchor.constraint(equalTo: drop.bottomAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: title.trailingAnchor),

            statusLabel.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -8),
            spinner.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            spinner.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),

            footer.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    // MARK: 操作

    @objc private func settingsChanged() {
        Settings.format = OutputFormat.allCases[max(0, formatPopup.indexOfSelectedItem)]
        Settings.longDigitsAsText = digitsPopup.indexOfSelectedItem == 0
        Settings.encoding = SourceEncoding.allCases[max(0, encodingPopup.indexOfSelectedItem)]
        Settings.delimiter = DelimiterChoice.allCases[max(0, delimiterPopup.indexOfSelectedItem)]
        Settings.openInExcel = openCheckbox.state == .on
    }

    private func currentOptions() -> ConversionOptions {
        ConversionOptions(format: Settings.format,
                          typing: TypingOptions(longDigitsAsText: Settings.longDigitsAsText),
                          encoding: Settings.encoding,
                          delimiter: Settings.delimiter)
    }

    @objc private func chooseFiles() {
        guard ready else { return }
        let panel = NSOpenPanel()
        panel.title = "変換するファイルを選択"
        panel.prompt = "変換"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        var types: [UTType] = [.commaSeparatedText, .tabSeparatedText, .plainText]
        if let csv = UTType(filenameExtension: "csv") { types.append(csv) }
        panel.allowedContentTypes = types
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.enqueue(panel.urls)
        }
    }

    @objc private func clearLog() {
        logView.string = ""
    }

    @objc private func showAbout() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let alert = NSAlert()
        alert.messageText = "CSV to XLSX Converter \(version)"
        alert.informativeText = "CSV・TSVファイルを文字化けや数値の自動変換なしでExcelに渡すアプリです。変換の規則は同梱の「はじめに.txt」をご覧ください。"
        alert.runModal()
    }

    private func enqueue(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pending.append(urls)
        runNext()
    }

    private func setBusy(_ value: Bool) {
        busy = value
        selectButton.isEnabled = !value
        for control in [formatPopup!, digitsPopup!, encodingPopup!, delimiterPopup!] { control.isEnabled = !value }
        openCheckbox.isEnabled = !value
        if value { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private func runNext() {
        guard ready, !busy, !pending.isEmpty, let converter else { return }
        let urls = pending.removeFirst()
        let options = currentOptions()
        setBusy(true)
        statusLabel.stringValue = "変換しています…"
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        appendLog("—— \(time) ——", bold: true)
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [ItemResult] = []
            for url in urls {
                guard Converter.acceptedExtensions.contains(url.pathExtension.lowercased()) else {
                    results.append(ItemResult(input: url, report: nil, error: "対象外のファイルです（.csv / .tsv / .txt のみ）。"))
                    continue
                }
                do {
                    results.append(ItemResult(input: url, report: try converter.convert(url, options: options), error: nil))
                } catch {
                    results.append(ItemResult(input: url, report: nil, error: error.localizedDescription))
                }
            }
            DispatchQueue.main.async { [weak self] in self?.finish(results, options: options) }
        }
    }

    private func finish(_ results: [ItemResult], options: ConversionOptions) {
        var notices: [String] = []
        var outputs: [URL] = []
        for item in results {
            if let report = item.report {
                outputs.append(report.output)
                let c = report.counts
                appendLog("✓ \(item.input.lastPathComponent) → \(report.output.lastPathComponent)\(report.reusedExisting ? "（同じ内容の既存ファイルを使用）" : "")")
                appendLog("   \(report.encodingName) / \(report.delimiterName) / \(report.rowCount)行×\(report.columnCount)列")
                appendLog("   数値 \(c.numbers) ・ 日付と時刻 \(c.dates) ・ 文字列 \(c.texts)（うち変換から保護 \(c.protected)）")
                if report.output.deletingLastPathComponent() != item.input.deletingLastPathComponent() {
                    appendLog("   保存先: \(report.output.path)")
                }
                for warning in report.warnings {
                    appendLog("   ⚠︎ \(warning)", warning: true)
                    notices.append("\(item.input.lastPathComponent)：\(warning)")
                }
            } else {
                appendLog("✗ \(item.input.lastPathComponent)：\(item.error ?? "不明なエラー")", warning: true)
                notices.append("\(item.input.lastPathComponent)：\(item.error ?? "不明なエラー")")
            }
        }
        let succeeded = outputs.count
        let failed = results.count - succeeded

        let complete: ([String]) -> Void = { [weak self] openNotices in
            guard let self else { return }
            for note in openNotices { self.appendLog("⚠︎ \(note)", warning: true) }
            let all = notices + openNotices
            self.statusLabel.stringValue = "完了：変換 \(succeeded)件" + (failed > 0 ? " ・ 失敗 \(failed)件" : "") +
                (all.isEmpty ? "" : " ・ 注意 \(all.count)件")
            self.showNotices(all) {
                self.setBusy(false)
                self.runNext()
            }
        }
        if Settings.openInExcel && !outputs.isEmpty {
            statusLabel.stringValue = "Excelで開いています…"
            ExcelLauncher.open(outputs, completion: complete)
        } else {
            complete([])
        }
    }

    private func showNotices(_ notices: [String], then: @escaping () -> Void) {
        guard !notices.isEmpty else { then(); return }
        let alert = NSAlert()
        alert.messageText = "確認してください"
        var text = notices.prefix(6).joined(separator: "\n\n")
        if notices.count > 6 { text += "\n\nほか\(notices.count - 6)件。結果欄をご覧ください。" }
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if window.isVisible {
            alert.beginSheetModal(for: window) { _ in then() }
        } else {
            alert.runModal()
            then()
        }
    }

    private func appendLog(_ text: String, bold: Bool = false, warning: Bool = false) {
        let font: NSFont = bold ? .monospacedSystemFont(ofSize: 11, weight: .semibold) : .monospacedSystemFont(ofSize: 11, weight: .regular)
        let color: NSColor = warning ? .systemOrange : .labelColor
        logView.textStorage?.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: color]))
        logView.scrollToEndOfDocument(nil)
    }
}
