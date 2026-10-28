#!/usr/bin/env bash
# Кладёт geoip.dat/geosite.dat в assets приложения (нужны правилам маршрутизации
# вида geoip:ru / geosite:category-ru в конфигах Remnawave).
# Набор runetfreedom — это v2fly + дополнительные списки для РФ.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/android/app/src/main/assets"
BASE="${GEO_BASE:-https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download}"
mkdir -p "$DEST"
for f in geoip.dat geosite.dat; do
  curl -fL --retry 3 -o "$DEST/$f" "$BASE/$f"
done
ls -la "$DEST"
