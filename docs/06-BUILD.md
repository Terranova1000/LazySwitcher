# 06 — Сборка, подпись, распространение

## 1. Что нужно на машине

- Xcode 16 или новее (macOS 15 Sequoia)
- Python 3.11+ и `pip install spylls` — для раскрытия словарей hunspell.
  Системный `/usr/bin/python3` на macOS 15 — это **3.9**, его не хватает, и ставить
  в него пакеты нельзя. Заводим отдельное окружение:
  `brew install python@3.12 && python3.12 -m venv Tools/.venv && Tools/.venv/bin/pip install spylls`
- **`brew install openssl@3`** — системный `/usr/bin/openssl` на macOS это LibreSSL,
  а в нём нет опции `pkcs12 -legacy`, без которой Связка ключей не примет сертификат
- `create-dmg` для сборки образа (`brew install create-dmg`), либо `hdiutil` вручную

---

## 2. Создание проекта в Xcode

Один раз, руками:

1. **File → New → Project → macOS → App**
2. Product Name: `LazySwitcher`
   Bundle Identifier: `com.lazyswitcher.app`
   Interface: **AppKit** (не SwiftUI)
   Language: Swift
3. Снять галочку «Include Tests» не нужно — тесты пригодятся.
4. В настройках таргета:
   - Signing & Capabilities → **удалить App Sandbox**, если он добавился
   - Signing & Capabilities → включить **Hardened Runtime**
   - Deployment Target: **macOS 14.0**
   - Build Settings → Architectures: `Standard Architectures (arm64, x86_64)`,
     Build Active Architecture Only: **No** для Release
5. Info.plist:
   ```xml
   <key>LSUIElement</key><true/>
   <key>NSAccessibilityUsageDescription</key>
   <string>Нужно, чтобы замечать текст, набранный не в той раскладке, и исправлять его.</string>
   <key>CFBundleName</key><string>Lazy Switcher</string>
   ```
6. Для Debug-конфигурации переопределить bundle ID на `com.lazyswitcher.app.debug`,
   чтобы отладочные сборки не портили разрешения релизной версии.

---

## 3. Сертификат подписи — один раз и навсегда

`scripts/make-cert.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

NAME="Lazy Switcher Signing"
OUT="$HOME/.lazyswitcher-signing"
mkdir -p "$OUT" && cd "$OUT"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "Сертификат «$NAME» уже есть в связке ключей."
  exit 0
fi

# ВАЖНО: /usr/bin/openssl на macOS — это LibreSSL, в нём нет -legacy.
# Берём OpenSSL 3 из Homebrew.
OPENSSL="$(brew --prefix openssl@3)/bin/openssl"
[ -x "$OPENSSL" ] || { echo "Нужен openssl@3: brew install openssl@3"; exit 1; }

"$OPENSSL" req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout dev.key -out dev.crt -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning"

# -legacy обязателен: без него Связка ключей не примет файл
"$OPENSSL" pkcs12 -export -legacy -in dev.crt -inkey dev.key \
  -out dev.p12 -password pass:lazyswitcher

security import dev.p12 -k "$HOME/Library/Keychains/login.keychain-db" \
  -P lazyswitcher -T /usr/bin/codesign

cat <<'EOS'

Готово. Остался один шаг вручную:

  1. Открыть «Связку ключей» (Keychain Access)
  2. Найти сертификат «Lazy Switcher Signing»
  3. Двойной клик → раскрыть «Доверять»
  4. «Подписывание кода» → «Всегда доверять»

ВАЖНО: файл ~/.lazyswitcher-signing/dev.p12 — это ключ ко всем выданным
разрешениям. Если он потеряется, каждому пользователю придётся выдавать
доступ заново. Сделайте копию в надёжном месте. В репозиторий не класть.

EOS
```

Добавить в `.gitignore`:
```
*.p12
*.key
*.crt
.lazyswitcher-signing/
```

---

## 4. Подпись

`scripts/sign.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
APP="${1:?путь к .app}"
IDENTITY="Lazy Switcher Signing"

# снизу вверх: сначала вложенное, потом сам бандл. --deep НЕ использовать.
find "$APP/Contents/Frameworks" -name "*.framework" -maxdepth 1 2>/dev/null | while read -r fw; do
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$fw"
done
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"

# --deep уместен при ПРОВЕРКЕ (в отличие от подписи, где он ломает бандл)
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Authority|Identifier"
echo "--- designated requirement ---"
codesign -d -r- "$APP"
```

Designated requirement надо один раз посмотреть глазами и запомнить: он должен
ссылаться на хеш сертификата. Если там вместо этого хеш содержимого — подпись
ad-hoc, и это ошибка.

---

## 5. DMG

`scripts/make-dmg.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
APP="${1:?путь к .app}"
VERSION=$(defaults read "$(cd "$APP" && pwd)/Contents/Info" CFBundleShortVersionString)

create-dmg \
  --volname "Lazy Switcher" \
  --window-size 540 380 \
  --icon-size 96 \
  --icon "Lazy Switcher.app" 140 190 \
  --app-drop-link 400 190 \
  --no-internet-enable \
  "dist/LazySwitcher-$VERSION.dmg" "$APP"
```

ZIP не используем: приложение, запущенное из `~/Downloads` после распаковки, попадает
под App Translocation, монтируется только для чтения в случайную папку, и настройки
перестают сохраняться.

---

## 6. Если разрешения «залипли»

`scripts/reset-tcc.sh`:

```bash
#!/usr/bin/env bash
tccutil reset Accessibility com.lazyswitcher.app
tccutil reset ListenEvent   com.lazyswitcher.app
tccutil reset PostEvent     com.lazyswitcher.app
# то же для отладочного бандла, иначе он продолжит тянуть старый грант
tccutil reset Accessibility com.lazyswitcher.app.debug
tccutil reset ListenEvent   com.lazyswitcher.app.debug
tccutil reset PostEvent     com.lazyswitcher.app.debug
echo "Сброшено. Откройте приложение и выдайте доступ заново."
```

Признак того, что нужно именно это: галочка в Системных настройках стоит, а в логах
`-25211` от AX-запросов и `nil` от `CGEvent.tapCreate`.

Приложение должно уметь распознавать это состояние само и предлагать кнопку, которая
копирует команду в буфер обмена. Пользователь не должен догадываться.

---

## 7. Чек-лист релиза

```
[ ] Версия поднята в Info.plist (и Short Version, и Build)
[ ] Модели пересобраны и проверены на детерминированность
[ ] Метрики детектора не хуже предыдущего релиза (Tools/eval)
[ ] Release-сборка, универсальный бинарник (arm64 + x86_64)
[ ] Подписано стабильным сертификатом, codesign --verify чистый
[ ] codesign -d -r- показывает DR по сертификату, а не по хешу содержимого
[ ] Проверено на чистой системе: установка, выдача доступа, работа
[ ] Проверено обновление поверх предыдущей версии: доступ сохранился
[ ] DMG собран, открывается, ярлык «Программы» на месте
[ ] Прогнан ручной сценарий из docs/08-TESTING.md
[ ] README содержит команду xattr и путь через Системные настройки
```

---

## 8. Обновления

Sparkle не используем: там есть сеть, а у нас правило «ноль сетевых соединений».
Пока — вручную: пользователь заходит на страницу Releases и качает новую версию.

Если позже захочется автопроверки обновлений, это будет **отдельная явная настройка,
выключенная по умолчанию**, с честным описанием, что именно она отправляет
(только запрос версии, без каких-либо данных о пользователе). Обсудить перед
реализацией — это единственное место, где мы можем нарушить собственное обещание.

Обновление всегда делается атомарно: новая версия распаковывается рядом и
переименовывается на место старой. Частично записанный бандл ломает подпись и
теряет выданные разрешения.
