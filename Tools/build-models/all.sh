#!/usr/bin/env bash
# Полная пересборка моделей из словарей. Занимает около 30 секунд.
set -euo pipefail
cd "$(dirname "$0")/../.."
PY=Tools/.venv/bin/python
[ -x "$PY" ] || { echo "Нет окружения: python3 -m venv Tools/.venv && Tools/.venv/bin/pip install spylls" >&2; exit 1; }

./Tools/build-models/fetch.sh
W=Tools/build-models/work
[ -s "$W/ru.words" ] || $PY Tools/build-models/expand.py "$W/ru_RU" --lang ru --out "$W/ru.words"
[ -s "$W/en.words" ] || $PY Tools/build-models/expand.py "$W/en_US" --lang en --out "$W/en.words"

for lang in ru en; do
  $PY Tools/build-models/build.py \
    --words "$W/$lang.words" --lang "$lang" \
    --out "LazySwitcher/Resources/$lang.lsmodel" \
    --held-out-out "Tools/eval/corpus/$lang.heldout.txt"
done
ls -la LazySwitcher/Resources/*.lsmodel
