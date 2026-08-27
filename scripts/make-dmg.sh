#!/usr/bin/env bash
# Собирает DMG штатным hdiutil, без внешних зависимостей.
#
# Почему DMG, а не ZIP: приложение, запущенное из ~/Downloads после распаковки
# ZIP, попадает под App Translocation — система монтирует его копию в случайную
# папку только для чтения, настройки перестают сохраняться, и понять причину
# невозможно. Сам образ от этого не спасает: запуск прямо из смонтированного DMG
# приводит к тому же. Снимает перенос через Finder — ради него в окне и лежит
# ярлык «Программы».
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:?путь к .app}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
NAME="Lazy Switcher"
OUT="dist/LazySwitcher-$VERSION.dmg"
STAGE=$(mktemp -d)

mkdir -p dist
rm -f "$OUT"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Программы"

cat > "$STAGE/Прочтите меня.txt" <<'EOS'
Lazy Switcher

1. Перетащите «Lazy Switcher» в папку «Программы» рядом.
   Именно перетащите: запуск прямо из этого образа сломает сохранение настроек.

2. Откройте приложение. macOS скажет, что не может проверить разработчика —
   у программы нет платной подписи Apple, и не будет. Чтобы открыть:
   Системные настройки → Конфиденциальность и безопасность → пролистать
   вниз → «Всё равно открыть».

   Либо одной командой в Терминале:
   xattr -dr com.apple.quarantine "/Applications/Lazy Switcher.app"

3. Выдайте доступ: Системные настройки → Конфиденциальность и безопасность →
   Универсальный доступ → включить «Lazy Switcher».
   После этого приложение перезапустится само.
EOS

hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$STAGE"

echo "· $OUT  ($(du -h "$OUT" | cut -f1))"
hdiutil verify "$OUT" >/dev/null && echo "· образ проверен"
