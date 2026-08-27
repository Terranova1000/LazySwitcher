#!/usr/bin/env bash
# Проверяет, что сетевой код в проекте ровно один и лежит там, где заявлено.
#
# Обещание «ноль соединений» держится не на честном слове, а на том, что его
# можно проверить за десять секунд. Раз в проекте появился один сетевой вызов,
# проверка обязана стать точнее, а не исчезнуть.
set -uo pipefail
cd "$(dirname "$0")/.."

ALLOWED="LazySwitcher/Support/UpdateChecker.swift"
PATTERN='URLSession|NSURLConnection|CFStream|Network\.framework|socket\(|getaddrinfo|CFSocket'

echo "Ищем сетевые вызовы в LazySwitcher/…"
FOUND=$(grep -rlnE "$PATTERN" LazySwitcher --include='*.swift' | sort)

UNEXPECTED=$(comm -23 <(echo "$FOUND") <(echo "$ALLOWED"))
if [ -n "$UNEXPECTED" ]; then
  echo "✗ Сетевой код вне разрешённого файла:" >&2
  echo "$UNEXPECTED" >&2
  exit 1
fi

if ! echo "$FOUND" | grep -qx "$ALLOWED"; then
  echo "· сетевого кода нет вообще"
else
  echo "· единственный сетевой файл: $ALLOWED"
  echo "· запросов в нём: $(grep -cE 'dataTask|URLRequest\(' "$ALLOWED")"
fi

echo
echo "Проверка вживую (нужно приложение в /Applications):"
echo "  lsof -i -a -p \$(pgrep -f 'Lazy Switcher') "
echo "Пока проверка обновлений выключена, список обязан быть пустым."
