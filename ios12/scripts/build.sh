#!/bin/sh
# Сборка IconTint для iOS 12–14 (ios12/) (rootful, iphoneos-arm, arm64 без PAC). Результат: packages/com.makr.icontint_<версия>_iphoneos-arm.deb
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/tweak"
L=../../lift
OUT="$ROOT/build"; rm -rf "$OUT"; mkdir -p "$OUT"
CC="xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=12.0 -fobjc-arc -O2 -ffp-contract=off -Wno-unguarded-availability-new -DIT_EDITING"
LIBS="-framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore -framework Accelerate -lz"
$CC -dynamiclib -I. -I$L Tweak.m ITSettings.m ITIconStore.m ITEditing.m ITCustomizeSheet.m ITIconSize.m \
    $L/ITRender.m $L/isopen.m $L/isopen_math.c $L/isopen_seg.c $L/isopen_comp.c $LIBS \
    -install_name /Library/MobileSubstrate/DynamicLibraries/IconTint.dylib -o "$OUT/IconTint.dylib"
# Экран настроек (бандл с локализацией en/ru); Preferences.framework приватный — dynamic_lookup
PB="$OUT/IconTintPrefs.bundle"; mkdir -p "$PB"
xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=12.0 -fobjc-arc -O2 -bundle -undefined dynamic_lookup \
    -framework UIKit -framework Foundation prefs/ITRRootListController.m -o "$PB/IconTintPrefs"
cp prefs/Info.plist prefs/Root.plist "$PB/"
for l in en ru; do mkdir -p "$PB/$l.lproj"; cp prefs/$l.lproj/Root.strings "$PB/$l.lproj/"; done
ldid -S "$PB/IconTintPrefs"; ldid -S "$OUT/IconTint.dylib"
cp -R layout "$OUT/pkg"
cp "$OUT/IconTint.dylib" "$OUT/pkg/Library/MobileSubstrate/DynamicLibraries/"
mkdir -p "$OUT/pkg/Library/PreferenceBundles"; cp -R "$PB" "$OUT/pkg/Library/PreferenceBundles/"
PL="$OUT/pkg/Library/PreferenceLoader/Preferences"
for n in IconTint IconTint@2x IconTint@3x; do cp "$ROOT/../assets/icon/$n.png" "$PL/$n.png"; done
sed -i '' 's|<key>cell</key><string>PSLinkCell</string>|&\
		<key>icon</key><string>IconTint.png</string>|' "$PL/IconTint.plist"
VER=$(grep '^Version:' layout/DEBIAN/control | cut -d' ' -f2)
printf 'Icon: file:///Library/PreferenceLoader/Preferences/IconTint@3x.png\n' >> "$OUT/pkg/DEBIAN/control"
find "$OUT/pkg" -name .DS_Store -delete
mkdir -p "$ROOT/packages"
DEB="$ROOT/packages/com.makr.icontint_${VER}_iphoneos-arm.deb"
dpkg-deb --root-owner-group -Zgzip -b "$OUT/pkg" "$DEB" >/dev/null
echo "Готово: $DEB"
