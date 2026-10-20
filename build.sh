#!/bin/bash
# CSV to XLSX Converter をビルドする。
# 必要なもの：Xcodeコマンドラインツール（xcrun swiftc）。インターネット接続は不要。
# 実行：ターミナルでこのフォルダに移動し、 ./build.sh
# 結果：このフォルダに「CSV to XLSX Converter.app」、dist/ に配布用ZIPとそのSHA-256ができる。経過は build.log に記録される。

set -uo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
LOG="$ROOT/build.log"
APP_NAME="CSV to XLSX Converter"
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
WORK="$(mktemp -d "${TMPDIR:-/tmp}/csvtoxlsx.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

say "== 1/4 変換エンジンのテスト"
run xcrun swiftc -swift-version 5 -O Sources/Core/*.swift Tests/main.swift -o "$WORK/CoreTests"
run "$WORK/CoreTests" "$ROOT" "$WORK/testwork"
grep -E "^(PASS|FAIL)" "$LOG" | tail -5

say "== 2/4 アプリのビルド（Apple Silicon / Intel）"
for arch in arm64 x86_64; do
    run xcrun swiftc -swift-version 5 -O -target "$arch-apple-macos13.0" \
        Sources/Core/*.swift Sources/App/*.swift -o "$WORK/CSVtoXLSXConverter-$arch"
done
run lipo -create "$WORK/CSVtoXLSXConverter-arm64" "$WORK/CSVtoXLSXConverter-x86_64" -output "$WORK/CSVtoXLSXConverter"

say "== 3/4 アプリの組み立てと署名"
APP="$WORK/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$WORK/CSVtoXLSXConverter" "$APP/Contents/MacOS/CSVtoXLSXConverter"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/cp932.bin Resources/eucjp.bin Resources/eucjp3.bin "$APP/Contents/Resources/"
cp -R Resources/AppIcon.iconset "$WORK/AppIcon.iconset"
run iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
# 他のユーザーアカウントからも読めるように権限をそろえる
run chmod -R u+rwX,go+rX,go-w "$APP"
run codesign --force --sign - --timestamp=none "$APP"
run codesign --verify --strict "$APP"

rm -rf "$ROOT/$APP_NAME.app"
run ditto --noextattr --norsrc "$APP" "$ROOT/$APP_NAME.app"

say "== 4/4 配布用ZIPの作成と確認"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)"
PACKAGE="$WORK/$APP_NAME $VERSION"
mkdir -p "$PACKAGE"
run ditto --noextattr --norsrc "$APP" "$PACKAGE/$APP_NAME.app"
run cp はじめに.txt LICENSE "$PACKAGE/"
run chmod 644 "$PACKAGE/はじめに.txt" "$PACKAGE/LICENSE"
ZIP_NAME="CSV-to-XLSX-Converter-$VERSION.zip"
mkdir -p "$ROOT/dist"
rm -f "$ROOT/dist/$ZIP_NAME" "$ROOT/dist/$ZIP_NAME.sha256"
run ditto -c -k --keepParent --noextattr --norsrc "$PACKAGE" "$ROOT/dist/$ZIP_NAME"
# 展開したアプリの署名が有効か確認する
run ditto -x -k "$ROOT/dist/$ZIP_NAME" "$WORK/unzipped"
run codesign --verify --strict "$WORK/unzipped/$APP_NAME $VERSION/$APP_NAME.app"
(cd "$ROOT/dist" && shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256")
say "ZIP: $ROOT/dist/$ZIP_NAME"
say "BUILD SUCCEEDED: $ROOT/$APP_NAME.app"
