#!/usr/bin/env bash
# Собирает Debug и ставит в /Applications.
#
# Почему именно /Applications, а не запуск из DerivedData: TCC привязывает
# выданное разрешение к паре (bundle ID, designated requirement) И к пути.
# Приложение, живущее в DerivedData, при каждой пересборке оказывается по
# новому пути, и разрешение приходится выдавать заново — что маскирует ровно
# тот эффект, который M0 должен измерить. См. docs/04-PLATFORM.md §6.2.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="/Applications/Lazy Switcher.app"

xcodebuild -project LazySwitcher.xcodeproj -scheme LazySwitcher \
  -configuration Debug -derivedDataPath build build \
  -quiet CODE_SIGN_IDENTITY="Lazy Switcher Signing"

SRC="build/Build/Products/Debug/Lazy Switcher.app"

# Выгружаем работающую копию, иначе перезапись повредит подпись живого процесса
pkill -f "/Applications/Lazy Switcher.app/Contents/MacOS/Lazy Switcher" 2>/dev/null || true
sleep 0.5

# Замена целиком, а не поверх: частично записанный бандл ломает подпись,
# и вместе с ней теряется выданное разрешение
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

echo "· установлено: $DEST"
codesign -d -r- "$DEST" 2>&1 | grep designated
open "$DEST"
echo "· запущено"
