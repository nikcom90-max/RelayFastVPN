#!/usr/bin/env bash
# Генерирует android/-проект Flutter и накладывает на него наш нативный слой
# (VpnService + Xray-core). Запускать из корня репозитория:  tools/bootstrap.sh
#
# Переменные:
#   APP_ID    — applicationId (по умолчанию app.relayfast)
#   APP_NAME  — имя приложения на лаунчере (по умолчанию RelayFastVPN)
set -euo pipefail

APP_ID="${APP_ID:-app.relayfast}"
APP_NAME="${APP_NAME:-RelayFastVPN}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# namespace/Kotlin-пакет фиксирован: app.relayfast (org=app, name=relayfast).
if [ ! -d android ]; then
  flutter create --platforms=android --org app --project-name relayfast --no-pub .
fi

OVER="$ROOT/android_overlay"
MAIN="$ROOT/android/app/src/main"
KDIR="$MAIN/kotlin/app/relayfast"
mkdir -p "$KDIR" "$MAIN/res/values" "$ROOT/android/app/libs"

for f in MainActivity VpnBus VpnSvc XrayCore; do
  cp "$OVER/kotlin/$f.kt" "$KDIR/"
done
cp "$OVER/AndroidManifest.xml" "$MAIN/AndroidManifest.xml"
cp "$OVER/proguard-rules.pro" "$ROOT/android/app/proguard-rules.pro"
mkdir -p "$MAIN/res/xml"
cp "$OVER/res/xml/update_paths.xml" "$MAIN/res/xml/update_paths.xml"
sed "s/__APP_NAME__/${APP_NAME}/" "$OVER/res/strings.xml" > "$MAIN/res/values/strings.xml"

# Тест-пример, который создаёт flutter create, не подходит нашему приложению.
rm -f "$ROOT/test/widget_test.dart"

# Если flutter create положил Java/Kotlin MainActivity в другое место — убираем дубль.
find "$MAIN" -name 'MainActivity.*' -not -path "$KDIR/*" -delete 2>/dev/null || true

GRADLE="$ROOT/android/app/build.gradle.kts"
[ -f "$GRADLE" ] || GRADLE="$ROOT/android/app/build.gradle"

# applicationId и minSdk (Notification.Action/IpPrefix требуют >= 24 для простоты).
sed -i -E "s/applicationId\s*=?\s*\"[^\"]*\"/applicationId = \"${APP_ID}\"/" "$GRADLE"
sed -i -E "s/minSdk(Version)?\s*=?\s*flutter\.minSdkVersion/minSdk = 24/" "$GRADLE"

if ! grep -q "libs/libv2ray.aar" "$GRADLE"; then
  if [[ "$GRADLE" == *.kts ]]; then
    cat >> "$GRADLE" <<'KTS'

dependencies {
    implementation(files("libs/libv2ray.aar"))
}

android {
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
    buildTypes {
        getByName("release") {
            proguardFiles(file("proguard-rules.pro"))
        }
    }
}
KTS
  else
    cat >> "$GRADLE" <<'GROOVY'

dependencies {
    implementation files('libs/libv2ray.aar')
}

android {
    packagingOptions {
        jniLibs {
            useLegacyPackaging = true
        }
    }
    buildTypes {
        release {
            proguardFiles file('proguard-rules.pro')
        }
    }
}
GROOVY
  fi
fi

if [ ! -f "$ROOT/android/app/libs/libv2ray.aar" ]; then
  echo "WARN: android/app/libs/libv2ray.aar не найден — запустите tools/build_xray_core.sh" >&2
fi
# Иконка приложения из assets/logo.jpg (Pillow).
python3 -c "import PIL" 2>/dev/null || python3 -m pip install --quiet --break-system-packages pillow || python3 -m pip install --quiet pillow
python3 - "$ROOT" <<'PY'
import sys, os
from PIL import Image
root = sys.argv[1]
src = Image.open(os.path.join(root, "assets/logo.jpg")).convert("RGB")
for d, px in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
    out = os.path.join(root, "android/app/src/main/res", "mipmap-" + d)
    os.makedirs(out, exist_ok=True)
    src.resize((px, px), Image.LANCZOS).save(os.path.join(out, "ic_launcher.png"))
# Adaptive-иконка (Android 8+): фон + передний план из assets/icon.
import shutil
res = os.path.join(root, "android/app/src/main/res")
os.makedirs(os.path.join(res, "drawable-nodpi"), exist_ok=True)
os.makedirs(os.path.join(res, "mipmap-anydpi-v26"), exist_ok=True)
shutil.copy(os.path.join(root, "assets/icon/ic_bg.png"), os.path.join(res, "drawable-nodpi/ic_launcher_bg.png"))
shutil.copy(os.path.join(root, "assets/icon/ic_fg.png"), os.path.join(res, "drawable-nodpi/ic_launcher_fg.png"))
xml = '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_bg"/>
    <foreground android:drawable="@drawable/ic_launcher_fg"/>
</adaptive-icon>
'''
for n in ("ic_launcher.xml", "ic_launcher_round.xml"):
    open(os.path.join(res, "mipmap-anydpi-v26", n), "w").write(xml)
PY

echo "OK: проект готов. Дальше: flutter pub get && flutter build apk --release --split-per-abi"
