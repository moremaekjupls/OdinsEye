#!/bin/bash
# E2E: настоящее приложение на временных данных. Настоящий config.json, сокет и
# окна пользователя не трогаются (ODINSEYE_SUPPORT_DIR).
#
# 1. `--e2e`: приложение само проходит сценарий (ползунки, второй писатель,
#    агент, нажатие на обложку и обратно) и пишет отчёт.
# 2. Замок: второй экземпляр на те же данные должен выйти сам, первый остаться.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

swift build >/dev/null 2>&1 || { echo "E2E: сборка не прошла"; swift build 2>&1 | tail -20; exit 1; }
BIN="$(swift build --show-bin-path)/OdinsEye"
DATA="$(mktemp -d /tmp/odinseye-e2e.XXXXXX)"
FIRST=""
# Не `kill 0`: с пустой переменной он убил бы всю группу процессов, вместе с вызвавшим.
trap '[ -n "$FIRST" ] && kill "$FIRST" 2>/dev/null; rm -rf "$DATA"' EXIT
export ODINSEYE_SUPPORT_DIR="$DATA"
FAIL=0

echo "== сценарий внутри приложения"
# macOS без `timeout`: ждём до 60 секунд и добиваем, если завис.
"$BIN" --e2e "$DATA/report.json" >"$DATA/app.log" 2>&1 &
APP=$!
for _ in $(seq 1 120); do kill -0 $APP 2>/dev/null || break; sleep 0.5; done
kill -0 $APP 2>/dev/null && { echo "FAIL: сценарий завис, убиваю"; kill -9 $APP; }
wait $APP 2>/dev/null
CODE=$?
if [ ! -f "$DATA/report.json" ]; then
  echo "FAIL: отчёта нет (код $CODE)"; tail -20 "$DATA/app.log"; exit 1
fi
python3 - "$DATA/report.json" <<'PY' || FAIL=1
import json, sys
rows = json.load(open(sys.argv[1]))
bad = 0
for r in rows:
    print(("PASS " if r["ok"] else "FAIL ") + r["name"] + ("  " + r["detail"] if not r["ok"] and r["detail"] else ""))
    bad += not r["ok"]
sys.exit(1 if bad else 0)
PY
mkdir -p "$ROOT/build/e2e" && cp "$DATA"/e2e-*.png "$ROOT/build/e2e/" 2>/dev/null

echo "== второй экземпляр на те же данные выходит сам"
rm -f "$DATA/instance.lock"
"$BIN" >"$DATA/first.log" 2>&1 & FIRST=$!
sleep 3
"$BIN" >"$DATA/second.log" 2>&1 & SECOND=$!
sleep 3
if kill -0 $SECOND 2>/dev/null; then echo "FAIL: второй экземпляр остался жить"; kill $SECOND; FAIL=1; else echo "PASS второй вышел"; fi
if kill -0 $FIRST 2>/dev/null; then echo "PASS первый работает"; else echo "FAIL: первый упал"; FAIL=1; fi

[ $FAIL -eq 0 ] && echo "E2E: всё зелёное" || echo "E2E: есть падения"
exit $FAIL
