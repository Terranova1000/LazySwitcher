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

# Отдельный путь, а не боевой.
#
# Debug-сборка несёт get-task-allow (его добавляет Xcode сам, в Debug.entitlements
# его нет) и послабление library validation. Вместе с выданным Accessibility это
# готовый обход TCC: любой процесс от имени пользователя делает task_for_pid и
# подгружает в приложение неподписанную библиотеку, наследуя права на чтение и
# синтез клавиатурных событий, которых сам никогда бы не получил.
#
# Bundle ID у сборок и так разные, поэтому разрешения ведутся раздельно и ничего
# не теряется. А по боевому пути должен лежать боевой бандл.
DEST="/Applications/Lazy Switcher (debug).app"

xcodebuild -project LazySwitcher.xcodeproj -scheme LazySwitcher \
  -configuration Debug -derivedDataPath build build \
  -quiet CODE_SIGN_IDENTITY="Lazy Switcher Signing"

SRC="build/Build/Products/Debug/Lazy Switcher.app"

# Выгружаем работающую копию, иначе перезапись повредит подпись живого процесса
# Скобки в шаблоне pkill -f — это регулярное выражение, а не литерал, поэтому
# «(debug)» совпадает со строкой «debug» без скобок и НЕ совпадает с настоящим
# путём. Из-за этого старый процесс переживал переустановку: бандл на диске
# подменялся, а работал прежний бинарник со старого inode — и правки «не
# применялись» без единого сообщения об ошибке.
pkill -f "Lazy Switcher \\(debug\\).app/Contents/MacOS" 2>/dev/null || true
sleep 0.5

# Замена целиком, а не поверх: частично записанный бандл ломает подпись,
# и вместе с ней теряется выданное разрешение
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

echo "· установлено: $DEST"
codesign -d -r- "$DEST" 2>&1 | grep designated
open "$DEST"
echo "· запущено"
