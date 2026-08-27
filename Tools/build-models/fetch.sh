#!/usr/bin/env bash
# Скачивает исходные словари. Только BSD-лицензированные источники —
# см. docs/05-DATA.md §2 и §3, там же разобрано, что не берём и почему.
set -euo pipefail
cd "$(dirname "$0")/work"

BASE="https://raw.githubusercontent.com/LibreOffice/dictionaries/master"
fetch() {
  local url="$1" out="$2"
  [ -s "$out" ] && { echo "· $out уже есть"; return; }
  curl -fsSL --retry 3 -o "$out" "$url"
  echo "· $out  $(wc -c < "$out" | tr -d ' ') байт"
}

fetch "$BASE/ru_RU/ru_RU.dic" ru_RU.dic
fetch "$BASE/ru_RU/ru_RU.aff" ru_RU.aff
fetch "$BASE/en/en_US.dic" en_US.dic
fetch "$BASE/en/en_US.aff" en_US.aff
fetch "$BASE/ru_RU/README_ru_RU.txt" ru_RU.LICENSE.txt || true
fetch "$BASE/en/README_en_US.txt" en_US.LICENSE.txt || true
