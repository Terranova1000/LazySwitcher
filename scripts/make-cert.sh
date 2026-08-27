#!/usr/bin/env bash
# Создаёт самоподписанный сертификат для подписи Lazy Switcher.
# Запускается один раз. Сертификат даёт стабильный designated requirement,
# благодаря которому выданное разрешение Accessibility переживает пересборку.
# См. docs/04-PLATFORM.md §6.2–6.3 и CLAUDE.md, правило 15.
set -euo pipefail

NAME="Lazy Switcher Signing"
OUT="$HOME/.lazyswitcher-signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
PASS="lazyswitcher"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "Сертификат «$NAME» уже готов к подписи."
  security find-identity -v -p codesigning | grep "$NAME"
  exit 0
fi

mkdir -p "$OUT" && cd "$OUT"

# Проблема с pkcs12 -legacy касается ТОЛЬКО OpenSSL 3.x: он по умолчанию шифрует
# контейнер AES-256/PBKDF2, чего Связка ключей не принимает, и -legacy возвращает
# старый набор алгоритмов. У системного LibreSSL 3.3 такого поведения нет — он и так
# пишет legacy-формат, поэтому флаг ему не нужен (и он его не знает).
# Проверено на macOS 15.7.7 / LibreSSL 3.3.6: импорт и подпись работают.
if [ -x "$(brew --prefix openssl@3 2>/dev/null)/bin/openssl" ]; then
  OPENSSL="$(brew --prefix openssl@3)/bin/openssl"; P12_LEGACY="-legacy"
else
  OPENSSL="/usr/bin/openssl"; P12_LEGACY=""
fi
echo "· openssl: $OPENSSL ($("$OPENSSL" version))"

if [ ! -f dev.crt ]; then
  "$OPENSSL" req -x509 -newkey rsa:2048 -days 3650 -nodes \
    -keyout dev.key -out dev.crt -subj "/CN=$NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" 2>/dev/null
  chmod 600 dev.key
  echo "· сертификат создан"
fi

if [ ! -f dev.p12 ]; then
  # shellcheck disable=SC2086
  "$OPENSSL" pkcs12 -export $P12_LEGACY -in dev.crt -inkey dev.key \
    -out dev.p12 -password "pass:$PASS"
  chmod 600 dev.p12
  echo "· упакован в p12"
fi

security import dev.p12 -k "$KEYCHAIN" -P "$PASS" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null
echo "· импортирован в связку ключей"

# Доверие на уровне пользователя — без sudo. Именно оно избавляет codesign
# от errSecInternalComponent при самоподписанном корне.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" dev.crt
echo "· помечен доверенным для подписи кода"

# Разрешаем codesign брать ключ без диалога о доступе к связке
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || \
  echo "  (не удалось выставить partition list — codesign может спросить пароль)"

echo
security find-identity -v -p codesigning | grep "$NAME" || {
  echo "Сертификат импортирован, но codesign его не видит. Проверьте связку ключей." >&2
  exit 1
}

cat <<EOS

Готово.

ВАЖНО: $OUT/dev.p12 — это ключ ко всем разрешениям, которые
выдадут пользователи. Если он потеряется, каждому придётся выдавать доступ
заново. Сделайте копию в надёжном месте. В репозиторий не класть.
EOS
