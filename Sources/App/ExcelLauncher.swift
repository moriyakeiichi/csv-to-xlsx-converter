import AppKit

@MainActor
enum ExcelLauncher {
    static func excelURL() -> URL? {
        let candidates = [
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Excel"),
            URL(fileURLWithPath: "/Applications/Microsoft Excel.app"),
        ]
        return candidates.compactMap { $0 }.first { Bundle(url: $0)?.bundleIdentifier == "com.microsoft.Excel" }
    }

    /// 出力ファイルをExcelで開く。完了時に、利用者に伝えるべきメッセージ（なければ空）を返す。
    static func open(_ files: [URL], completion: @escaping ([String]) -> Void) {
        guard !files.isEmpty else { completion([]); return }
        guard let excel = excelURL() else {
            for file in files { NSWorkspace.shared.open(file) }
            completion(["Microsoft Excelが見つからないため、既定のアプリで開きました。"])
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(files, withApplicationAt: excel, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    completion(["Excelを起動できませんでした（\(error.localizedDescription)）。出力ファイルは保存済みです。"])
                } else {
                    completion([])
                }
            }
        }
    }
}
