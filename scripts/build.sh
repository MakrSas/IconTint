#!/bin/sh
# Сборка IconTint (rootless, iphoneos-arm64, iOS 15+).
#   build.sh public — сборка твика (движок lift/isopen*.c)
set -e
MODE=${1:-public}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/tweak"
L=../lift
OUT="$ROOT/build/$MODE"
rm -rf "$OUT"; mkdir -p "$OUT"
CC="xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -fobjc-arc -O2 -ffp-contract=off -Wno-unguarded-availability-new -DIT_EDITING"
COMMON="Tweak.m ITSettings.m ITIconStore.m ITEditing.m ITCustomizeSheet.m ITIconSize.m $L/ITRender.m"
LIBS="-framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore -framework Accelerate -lz"
VER=$(grep '^Version:' layout/DEBIAN/control | cut -d' ' -f2)
case "$MODE" in
public)
    $CC -dynamiclib -I. -I$L $COMMON $L/isopen.m $L/isopen_math.c $L/isopen_seg.c $L/isopen_comp.c $LIBS -install_name @rpath/IconTint.dylib -o "$OUT/IconTint.dylib"
    ;;
*) echo "usage: build.sh public"; exit 1 ;;
esac
# Экран настроек (бандл с локализацией en/ru); Preferences.framework приватный — линкуем с dynamic_lookup
PB="$OUT/IconTintPrefs.bundle"; mkdir -p "$PB"
xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -fobjc-arc -O2 -bundle -undefined dynamic_lookup \
    -framework UIKit -framework Foundation prefs/ITRRootListController.m -o "$PB/IconTintPrefs"
cp prefs/Info.plist "$PB/"
cp prefs/Root.plist "$PB/"
for l in en ru; do mkdir -p "$PB/$l.lproj"; cp prefs/$l.lproj/Root.strings "$PB/$l.lproj/"; done
ldid -S "$PB/IconTintPrefs"
ldid -S "$OUT/IconTint.dylib"
cp -R layout "$OUT/pkg"
cp "$OUT/IconTint.dylib" "$OUT/pkg/var/jb/Library/MobileSubstrate/DynamicLibraries/"
mkdir -p "$OUT/pkg/var/jb/Library/PreferenceBundles"; cp -R "$PB" "$OUT/pkg/var/jb/Library/PreferenceBundles/"
# Иконка твика (assets/icon, светлая и тёмная): значок в Настройках и иконка пакета
PL="$OUT/pkg/var/jb/Library/PreferenceLoader/Preferences"
cp "$ROOT/assets/icon/IconTint.png" "$PL/IconTint.png"
cp "$ROOT/assets/icon/IconTint@2x.png" "$PL/IconTint@2x.png"
cp "$ROOT/assets/icon/IconTint@3x.png" "$PL/IconTint@3x.png"
cp "$ROOT/assets/icon/IconTint-light.png" "$PL/IconTint-light.png"
cp "$ROOT/assets/icon/IconTint-light@2x.png" "$PL/IconTint-light@2x.png"
cp "$ROOT/assets/icon/IconTint-light@3x.png" "$PL/IconTint-light@3x.png"
cp "$ROOT/assets/icon/IconTint-dark.png" "$PL/IconTint-dark.png"
cp "$ROOT/assets/icon/IconTint-dark@2x.png" "$PL/IconTint-dark@2x.png"
cp "$ROOT/assets/icon/IconTint-dark@3x.png" "$PL/IconTint-dark@3x.png"
sed -i '' 's|<key>cell</key><string>PSLinkCell</string>|&\
		<key>icon</key><string>IconTint.png</string>|' "$PL/IconTint.plist"
printf 'Icon: file:///var/jb/Library/PreferenceLoader/Preferences/IconTint@3x.png\n' >> "$OUT/pkg/DEBIAN/control"
find "$OUT/pkg" -name .DS_Store -delete
sed -i '' "s/^Version: .*/Version: $VER/" "$OUT/pkg/DEBIAN/control"
mkdir -p "$ROOT/packages"
DEB="$ROOT/packages/com.makr.icontint_${VER}_iphoneos-arm64.deb"
dpkg-deb --root-owner-group -Zgzip -b "$OUT/pkg" "$DEB" >/dev/null
echo "Готово: $DEB"
