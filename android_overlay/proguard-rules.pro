# libv2ray (Xray-core, gomobile) вызывается из Go через JNI — нельзя обфусцировать/вырезать.
-keep class libv2ray.** { *; }
-keep class go.** { *; }
-dontwarn libv2ray.**
-dontwarn go.**

# Сканер QR (mobile_scanner → CameraX + ML Kit): R8 вырезает нужные классы,
# из-за чего камера не запускается («getClass() on a null object reference»).
-keep class dev.steenbakker.mobile_scanner.** { *; }
-keep class androidx.camera.** { *; }
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-dontwarn com.google.mlkit.**
-dontwarn androidx.camera.**
