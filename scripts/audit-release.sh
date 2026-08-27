#!/usr/bin/env bash
# Проверяет готовый Release-бандл на то, чего в нём быть не должно.
#
# Проверки идут по собранному бинарнику, а не по исходникам: между «в коде стоит
# #if DEBUG» и «в бинарнике этого нет» лежит вся конфигурация сборки, и ошибиться
# там легко. Смотрим на то, что реально уедет пользователю.
set -uo pipefail

# ВНИМАНИЕ на конструкцию «команда | grep -q» под pipefail: grep -q закрывает
# канал на первом совпадении, команда слева получает SIGPIPE и завершается
# ненулевым кодом, а pipefail делает ненулевым весь конвейер — то есть удачная
# проверка выглядит как провалившаяся. Поэтому вывод всюду читается в
# переменную, а grep применяется уже к ней.
cd "$(dirname "$0")/.."
APP="${1:-build/Build/Products/Release/Lazy Switcher.app}"
BIN="$APP/Contents/MacOS/Lazy Switcher"
FAIL=0

say() { printf "%-52s %s\n" "$1" "$2"; }
ok()   { say "$1" "✓"; }
bad()  { say "$1" "✗ $2"; FAIL=1; }

[ -x "$BIN" ] || { echo "Нет бинарника: $BIN" >&2; exit 1; }

echo "── отладочные леса не должны существовать в релизе"
SYMBOLS=$(strings "$BIN" 2>/dev/null || true)
for needle in m5-selftest-run m4-selftest-run m0-sweep m0-report.txt m0-timeout-sweep; do
  if printf '%s' "$SYMBOLS" | grep -qF "$needle"; then
    bad "триггер «$needle»" "присутствует — леса попали в релиз"
  else
    ok "триггер «$needle» отсутствует"
  fi
done

echo
echo "── подпись и права"
ENTITLEMENTS=$(codesign -d --entitlements - "$APP" 2>/dev/null || true)
if printf '%s' "$ENTITLEMENTS" | grep -q "disable-library-validation"; then
  bad "entitlements" "послабление library validation утекло в Release"
else
  ok "entitlements без послаблений"
fi

DR=$(codesign -d -r- "$APP" 2>&1 | grep designated || true)
if echo "$DR" | grep -q "certificate leaf"; then
  ok "designated requirement по сертификату"
else
  bad "designated requirement" "не привязан к сертификату — разрешения не переживут обновление"
fi

SIGNATURE=$(codesign -dv "$APP" 2>&1 || true)
if printf '%s' "$SIGNATURE" | grep -q "flags=.*runtime"; then
  ok "Hardened Runtime включён"
else
  bad "Hardened Runtime" "выключен"
fi

echo
echo "── песочницы быть не должно (в ней недоступен Accessibility)"
if printf '%s' "$ENTITLEMENTS" | grep -q "app-sandbox"; then
  bad "песочница" "включена — Accessibility работать не будет"
else
  ok "песочницы нет"
fi

echo
echo "── ресурсы"
for res in ru.lsmodel en.lsmodel ru.lproj en.lproj; do
  if [ -e "$APP/Contents/Resources/$res" ]; then ok "$res на месте"; else bad "$res" "отсутствует"; fi
done
RESOURCES=$(ls "$APP/Contents/Resources/" 2>/dev/null || true)
if printf '%s' "$RESOURCES" | grep -q heldout; then
  bad "отложенный корпус" "уехал в бандл, ему там не место"
else
  ok "отложенного корпуса в бандле нет"
fi

echo
echo "── архитектуры"
ARCHS=$(lipo -info "$BIN" 2>/dev/null || true)
if printf '%s' "$ARCHS" | grep -q "x86_64 arm64\|arm64 x86_64"; then
  ok "универсальный бинарник"
else
  bad "архитектуры" "$(lipo -info "$BIN" 2>&1 | tail -1)"
fi

echo
[ $FAIL -eq 0 ] && echo "Всё чисто." || echo "Есть замечания — см. ✗ выше."
exit $FAIL
