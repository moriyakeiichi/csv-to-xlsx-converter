#!/bin/bash
# ダブルクリックで CSV Intact をビルドする（中身は build.sh を実行するだけ）
cd "$(dirname "$0")"
bash ./build.sh
echo
echo "このウインドウは閉じてかまいません。"
