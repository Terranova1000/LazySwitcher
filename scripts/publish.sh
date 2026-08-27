#!/usr/bin/env bash
# Создаёт репозиторий, заливает код и выкладывает релиз.
#
# Требует установленного и авторизованного gh:
#   brew install gh && gh auth login
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${1:-LazySwitcher}"
VISIBILITY="${2:-public}"

command -v gh >/dev/null || { echo "Нет gh: brew install gh && gh auth login" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh не авторизован: gh auth login" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "build/Build/Products/Release/Lazy Switcher.app/Contents/Info.plist" 2>/dev/null || echo "")
[ -n "$VERSION" ] || { echo "Сначала соберите релиз — см. docs/10-RELEASE.md" >&2; exit 1; }
DMG="dist/LazySwitcher-$VERSION.dmg"
[ -f "$DMG" ] || { echo "Нет образа $DMG" >&2; exit 1; }

OWNER=$(gh api user --jq .login)
echo "· пользователь: $OWNER, репозиторий: $REPO ($VISIBILITY), версия: $VERSION"

# Адрес в проверке обновлений обязан совпадать с настоящим, иначе приложение
# будет спрашивать про чужой репозиторий и всегда отвечать «обновлений нет».
EXPECTED="$OWNER/$REPO"
ACTUAL=$(grep -oE 'repository = "[^"]+"' LazySwitcher/Support/UpdateChecker.swift | cut -d'"' -f2)
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "✗ UpdateChecker указывает на «$ACTUAL», а репозиторий будет «$EXPECTED»." >&2
  echo "  Поправьте LazySwitcher/Support/UpdateChecker.swift, пересоберите и повторите." >&2
  exit 1
fi

if ! gh repo view "$EXPECTED" >/dev/null 2>&1; then
  gh repo create "$EXPECTED" --"$VISIBILITY" \
    --description "Исправляет текст, набранный не в той раскладке. macOS, бесплатно, локально." \
    --source=. --remote=origin --push
else
  git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$EXPECTED.git"
  git push -u origin HEAD
fi

git tag -f "v$VERSION" && git push -f origin "v$VERSION"
NOTES="NOTES-$VERSION.md"; [ -f "$NOTES" ] || NOTES=/dev/null
gh release create "v$VERSION" "$DMG" --title "$VERSION" --notes-file "$NOTES" || \
  gh release upload "v$VERSION" "$DMG" --clobber

echo "· готово: https://github.com/$EXPECTED/releases/tag/v$VERSION"
echo "· проверьте в приложении: «О программе» → «Проверить сейчас»"
