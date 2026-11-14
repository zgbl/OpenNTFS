#!/bin/sh
# 构建 OpenNTFS.app（输出到 build/OpenNTFS.app）
set -eu
cd "$(dirname "$0")"

# 1. 打过补丁的 ntfs-3g（FSKit 读写挂载需要）
[ -x vendor/dist/bin/ntfs-3g ] || vendor/build-ntfs-3g.sh

# 2. App 本体
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/OpenNTFS"

APP=build/OpenNTFS.app
C="$APP/Contents"
rm -rf "$APP"
mkdir -p "$C/MacOS" "$C/Resources" "$C/Helpers" "$C/Frameworks"
cp "$BIN" "$C/MacOS/OpenNTFS"
cp Resources/Info.plist "$C/Info.plist"
cp Resources/ntfs-helper.sh Resources/askpass.sh "$C/Resources/"
chmod 755 "$C/Resources/ntfs-helper.sh" "$C/Resources/askpass.sh"

# 3. 内置 ntfs-3g 及其依赖库（libfuse 由 macFUSE 提供，不打包）
cp vendor/dist/bin/ntfs-3g "$C/Helpers/ntfs-3g"
cp vendor/dist/lib/libntfs-3g.91.dylib "$C/Frameworks/"
INTL=$(otool -L vendor/dist/bin/ntfs-3g | awk '/libintl/{print $1}')
cp "$INTL" "$C/Frameworks/libintl.8.dylib"
chmod u+w "$C"/Frameworks/*.dylib
for f in "$C/Helpers/ntfs-3g" "$C"/Frameworks/*.dylib; do
    for dep in $(otool -L "$f" | awk 'NR>1 && /(libntfs-3g|libintl)/{print $1}'); do
        install_name_tool -change "$dep" "@executable_path/../Frameworks/$(basename "$dep")" "$f" 2>/dev/null
    done
done
install_name_tool -id "@executable_path/../Frameworks/libntfs-3g.91.dylib" "$C/Frameworks/libntfs-3g.91.dylib"
install_name_tool -id "@executable_path/../Frameworks/libintl.8.dylib" "$C/Frameworks/libintl.8.dylib"

# 4. 本地 ad-hoc 签名（自用足够；分发需换成开发者证书并公证）
codesign --force --sign - "$C"/Frameworks/*.dylib "$C/Helpers/ntfs-3g"
codesign --force --sign - "$APP"

echo "✅ 已生成 $APP"
echo "   安装：cp -R $APP /Applications/"
