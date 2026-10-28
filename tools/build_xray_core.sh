#!/usr/bin/env bash
# Собирает libv2ray.aar (Xray-core для Android) из AndroidLibXrayLite.
# Нужны: Go, JDK 17, Android SDK + NDK (ANDROID_HOME / ANDROID_NDK_HOME).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/.build/AndroidLibXrayLite}"
REF="${XRAY_LIB_REF:-}"   # пусто = актуальная ветка по умолчанию; можно указать тег/ветку

rm -rf "$WORK"
mkdir -p "$(dirname "$WORK")"
if [ -n "$REF" ]; then
  git clone --depth 1 --branch "$REF" https://github.com/2dust/AndroidLibXrayLite.git "$WORK"
else
  git clone --depth 1 https://github.com/2dust/AndroidLibXrayLite.git "$WORK"
fi
cd "$WORK"

go install golang.org/x/mobile/cmd/gomobile@latest
export PATH="$PATH:$(go env GOPATH)/bin"
gomobile init

bind() {
  go mod tidy -v
  gomobile bind -v -androidapi 24 -target=android/arm64,android/arm,android/amd64 \
    -trimpath -ldflags='-s -w -buildid= -checklinkname=0' ./
}

echo "Xray-core в AndroidLibXrayLite по умолчанию: $(go list -m github.com/xtls/xray-core 2>/dev/null || true)"
if [ "${XRAY_LATEST:-0}" = "1" ]; then
  cp go.mod go.mod.orig
  cp go.sum go.sum.orig 2>/dev/null || true
  echo "Обновляю Xray-core до последней версии..."
  if go get github.com/xtls/xray-core@latest && bind; then
    echo "Собрано с Xray-core: $(go list -m github.com/xtls/xray-core)"
  else
    echo "WARN: сборка с последним Xray-core не удалась — возвращаюсь к версии из AndroidLibXrayLite" >&2
    mv go.mod.orig go.mod
    [ -f go.sum.orig ] && mv go.sum.orig go.sum
    bind
  fi
else
  bind
fi

mkdir -p "$ROOT/android/app/libs"
cp libv2ray.aar "$ROOT/android/app/libs/libv2ray.aar"
echo "OK: $ROOT/android/app/libs/libv2ray.aar"
