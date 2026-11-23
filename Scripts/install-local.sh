#!/bin/bash
# Ставит собранное приложение в /Applications, сохраняя прошлую версию.
# Сначала verify: без зелёных тестов и E2E ничего не копируется.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> тесты"; Scripts/test.sh
echo "==> E2E"; Scripts/e2e.sh
echo "==> бандл"; Scripts/bundle.sh

APP=/Applications/OdinsEye.app
BACKUP_DIR="$HOME/Library/Application Support/OdinsEye-backups"
mkdir -p "$BACKUP_DIR"
if [ -d "$APP" ]; then
    STAMP="$(date +%Y%m%d-%H%M%S)"
    PREV="$BACKUP_DIR/OdinsEye-$STAMP.app"
    cp -R "$APP" "$PREV"
    echo "==> прошлая версия сохранена: $PREV (коммит $(git rev-parse --short HEAD))"
    echo "    откат: pkill -x OdinsEye; rm -rf $APP && cp -R \"$PREV\" $APP && open $APP"
fi
# Копию config.json тоже: настройки живут отдельно от приложения.
CONFIG="$HOME/Library/Application Support/OdinsEye/config.json"
[ -f "$CONFIG" ] && cp "$CONFIG" "$BACKUP_DIR/config-$(date +%Y%m%d-%H%M%S).json"

pkill -x OdinsEye 2>/dev/null || true
sleep 1
rm -rf "$APP"
cp -R build/OdinsEye.app "$APP"
open "$APP"
echo "==> установлено"
