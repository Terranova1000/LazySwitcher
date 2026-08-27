#!/usr/bin/env bash
# Подписывает готовый бандл стабильным самоподписанным сертификатом.
set -euo pipefail
APP="${1:?путь к .app}"
IDENTITY="${LS_IDENTITY:-Lazy Switcher Signing}"

security find-identity -v -p codesigning | grep -q "$IDENTITY" || {
  echo "Нет сертификата «$IDENTITY». Запустите ./scripts/make-cert.sh" >&2; exit 1; }

# Снизу вверх: вложенное раньше самого бандла. --deep при ПОДПИСИ не
# используем — он работает плохо и ломает подпись. При проверке, наоборот, нужен.
if [ -d "$APP/Contents/Frameworks" ]; then
  find "$APP/Contents/Frameworks" -maxdepth 1 \( -name "*.framework" -o -name "*.dylib" \) \
    -print0 | while IFS= read -r -d '' item; do
      codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$item"
    done
fi

# В Release entitlements нет вообще: послабление library validation нужно
# только тестам и живёт исключительно в Debug (00-DECISIONS.md, Н4).
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"

echo "── проверка"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Authority|Identifier|TeamIdentifier" || true

echo "── designated requirement"
DR=$(codesign -d -r- "$APP" 2>&1 | grep designated || true)
echo "$DR"
# Ради этого всё и затевалось: требование обязано ссылаться на хеш сертификата,
# а не на хеш содержимого. Иначе разрешения слетят при первом же обновлении.
if echo "$DR" | grep -q "cdhash"; then
  echo "✗ DR по хешу содержимого — это ad-hoc подпись. Разрешения не переживут обновление." >&2
  exit 1
fi
echo "✓ DR привязан к сертификату"
