#!/usr/bin/env bash
# Сколько раз скачали приложение и сколько установленных копий обновилось.
#
# Считает GitHub, а не приложение: приложение ничего никуда не сообщает и не
# будет (CLAUDE.md §2.1, правило 3). Отсюда и границы того, что можно узнать:
#
#   · «скачали»      — загрузки .dmg со страницы выпуска. Повторные загрузки
#                      одним человеком тоже считаются; установок так не узнать.
#   · «обновились»   — загрузки .app-update: столько установленных копий
#                      обновилось до этой версии из приложения. Такой файл
#                      берут версии с 1.14, поэтому считается начиная с выпуска
#                      после 1.14. До этого обновления шли через .dmg и сидят
#                      в первом столбце.
#
# Сколько копий установлено всего, не знает никто — и так и задумано.
set -euo pipefail
REPO="Terranova1000/LazySwitcher"

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  RELEASES=$(gh api "repos/$REPO/releases" --paginate)
  TRAFFIC=$(gh api "repos/$REPO/traffic/views" 2>/dev/null || true)
else
  RELEASES=$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=100")
  TRAFFIC=""
fi

RELEASES="$RELEASES" TRAFFIC="$TRAFFIC" python3 - <<'PY'
import json, os

raw = os.environ["RELEASES"]
# `gh api --paginate` склеивает страницы подряд: «][» между массивами.
releases = []
decoder = json.JSONDecoder()
index = 0
while index < len(raw):
    while index < len(raw) and raw[index].isspace():
        index += 1
    if index >= len(raw):
        break
    page, index = decoder.raw_decode(raw, index)
    releases.extend(page)

rows, manual_total, update_total = [], 0, 0
for release in releases:
    if release.get("draft"):
        continue
    manual = sum(a["download_count"] for a in release["assets"] if a["name"].endswith(".dmg"))
    updated = sum(a["download_count"] for a in release["assets"] if a["name"].endswith(".app-update"))
    has_update_asset = any(a["name"].endswith(".app-update") for a in release["assets"])
    manual_total += manual
    update_total += updated
    rows.append((release["tag_name"], release["published_at"][:10], manual,
                 str(updated) if has_update_asset else "—"))

print(f"{'версия':<10} {'выпущена':<11} {'скачали':>8} {'обновились':>11}")
for tag, date, manual, updated in rows:
    print(f"{tag:<10} {date:<11} {manual:>8} {updated:>11}")
print(f"{'всего':<22} {manual_total:>8} {update_total:>11}")

traffic = os.environ.get("TRAFFIC", "").strip()
if traffic:
    views = json.loads(traffic)
    print(f"\nСтраница на GitHub за 14 дней: {views.get('count', 0)} просмотров, "
          f"{views.get('uniques', 0)} посетителей")
PY
