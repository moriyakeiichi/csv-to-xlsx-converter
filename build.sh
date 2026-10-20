#!/bin/bash
# CSV Excel Viewer をビルドする。
# 必要なもの：Xcodeコマンドラインツール（xcrun swiftc）。インターネット接続は不要。
# 実行：ターミナルでこのフォルダに移動し、 ./build.sh
# 結果：このフォルダに「CSV Excel Viewer.app」ができる。経過は build.log に記録される。

set -uo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
LOG="$ROOT/build.log"
APP_NAME="CSV Excel Viewer"
: > "$LOG"

say() { echo "$@" | tee -a "$LOG"; }
run() {
    "$@" >>"$LOG" 2>&1
    local status=$?
    if [ $status -ne 0 ]; then
        say "失敗しました: $*"
        say "BUILD FAILED"
        exit $status
    fi
}

# 作業はDocumentsの外（一時フォルダ）で行う。Finderの付加情報で署名が崩れるのを避けるため。
WORK="$(mktemp -d "${TMPDIR:-/tmp}/csvexcelviewer.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

say "== 1/3 変換エンジンのテスト"
run xcrun swiftc -swift-version 5 -O Sources/Core/*.swift Tests/main.swift -o "$WORK/CoreTests"
run "$WORK/CoreTests" "$ROOT" "$WORK/testwork"
grep -E "^(PASS|FAIL)" "$LOG" | tail -5

say "== 2/3 アプリのビルド（Apple Silicon / Intel）"
for arch in arm64 x86_64; do
    run xcrun swiftc -swift-version 5 -O -target "$arch-apple-macos13.0" \
        Sources/Core/*.swift Sources/App/*.swift -o "$WORK/CSVExcelViewer-$arch"
done
run lipo -create "$WORK/CSVExcelViewer-arm64" "$WORK/CSVExcelViewer-x86_64" -output "$WORK/CSVExcelViewer"

say "== 3/3 アプリの組み立てと署名"
APP="$WORK/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$WORK/CSVExcelViewer" "$APP/Contents/MacOS/CSVExcelViewer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/cp932.bin Resources/eucjp.bin Resources/eucjp3.bin "$APP/Contents/Resources/"
cp -R Resources/AppIcon.iconset "$WORK/AppIcon.iconset"
run iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
run codesign --force --sign - --timestamp=none "$APP"
run codesign --verify --strict "$APP"

rm -rf "$ROOT/$APP_NAME.app"
run ditto --noextattr --norsrc "$APP" "$ROOT/$APP_NAME.app"
say "BUILD SUCCEEDED: $ROOT/$APP_NAME.app"
