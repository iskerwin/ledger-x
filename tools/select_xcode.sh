#!/bin/bash
# Pin the cloud image to Xcode 26.6. Do not fall through to another Xcode.
set -euo pipefail
app=/Applications/Xcode_26.6.app
if [[ ! -d "$app/Contents/Developer" ]]; then
  echo "未找到 Xcode 26.6（$app）。不会改用其他 Xcode。"
  ls -d /Applications/Xcode*.app || true
  exit 1
fi
sudo xcode-select -s "$app/Contents/Developer"
selected=$(xcode-select -p)
if [[ "$selected" != "$app/Contents/Developer" ]]; then
  echo "xcode-select 仍指向 ${selected}"
  exit 1
fi
version=$(xcodebuild -version)
printf '%s\n' "$version"
printf '%s\n' "$version" | grep -q '^Xcode 26\.6'
xcrun simctl list runtimes
