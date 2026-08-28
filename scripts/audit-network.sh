#!/usr/bin/env bash
# Проверяет, что сетевой код в проекте ровно один и лежит там, где заявлено.
#
# Обещание «ноль соединений» держится не на честном слове, а на том, что его
# можно проверить за десять секунд. Раз в проекте появился один сетевой вызов,
# проверка обязана стать точнее, а не исчезнуть.
set -uo pipefail
cd "$(dirname "$0")/.."

# Два файла и только два: проверка версии и загрузка обновления.
ALLOWED="LazySwitcher/Support/UpdateChecker.swift
LazySwitcher/Support/Updater.swift"
PATTERN='URLSession|NSURLConnection|CFStream|Network\.framework|socket\(|getaddrinfo|CFSocket'

echo "Ищем сетевые вызовы в LazySwitcher/…"
FOUND=$(grep -rlnE "$PATTERN" LazySwitcher --include='*.swift' | sort)

UNEXPECTED=$(comm -23 <(echo "$FOUND" | sort) <(echo "$ALLOWED" | sort))
if [ -n "$UNEXPECTED" ]; then
  echo "✗ Сетевой код вне разрешённого файла:" >&2
  echo "$UNEXPECTED" >&2
  exit 1
fi

if [ -z "$FOUND" ]; then
  echo "· сетевого кода нет вообще"
else
  echo "· сетевые файлы (оба разрешены):"
  echo "$FOUND" | sed 's/^/    /'
  echo "· запросов в них: $(grep -chE 'dataTask|downloadTask|URLRequest\(' $FOUND | paste -sd+ - | bc)"
fi

echo
echo "── проверка подписи при обновлении обязана существовать"
if grep -q "SecStaticCodeCheckValidityWithErrors" LazySwitcher/Support/Updater.swift &&
   grep -q "SecCodeCopyDesignatedRequirement" LazySwitcher/Support/Updater.swift; then
  echo "· требование берётся у работающего бинарника и сверяется со скачанным"
else
  echo "✗ Обновление устанавливается без сверки подписи. Это недопустимо." >&2
  exit 1
fi

echo
echo "Проверка вживую (нужно приложение в /Applications):"
echo "  lsof -i -a -p \$(pgrep -f 'Lazy Switcher') "
echo "Пока проверка обновлений выключена, список обязан быть пустым."
