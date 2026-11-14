#!/bin/sh
# 构建打过 OpenNTFS 补丁的 ntfs-3g，输出到 vendor/dist
# 依赖：macFUSE（提供 /usr/local/include/fuse.h 与 libfuse）、brew install autoconf automake libtool pkgconf gettext
set -eu
cd "$(dirname "$0")"
VER=2026.9.28
SHA=8a75293f07bf40df5701d296de32a4cb0e46d6ae135abb4f41b438df9868a390
SRC=ntfs-3g-$VER
DIST="$(pwd)/dist"

[ -f "$SRC.tar.gz" ] || curl -fsSL -o "$SRC.tar.gz" "https://github.com/tuxera/ntfs-3g/archive/refs/tags/$VER.tar.gz"
echo "$SHA  $SRC.tar.gz" | shasum -a 256 -c -

rm -rf "$SRC" && tar xzf "$SRC.tar.gz"
patch -d "$SRC" -p1 < openntfs-unprivileged-fskit.patch

export PATH="/opt/homebrew/bin:$PATH"
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig"
export CPPFLAGS="-I/opt/homebrew/include" LDFLAGS="-L/opt/homebrew/lib -lintl"
cd "$SRC"
./autogen.sh >/dev/null
./configure --prefix="$DIST" --exec-prefix="$DIST" --with-fuse=external \
    --disable-ldconfig --disable-mtab --disable-ntfsprogs >/dev/null
make -j"$(sysctl -n hw.ncpu)" >/dev/null

rm -rf "$DIST" && mkdir -p "$DIST/bin" "$DIST/lib"
cp src/.libs/ntfs-3g "$DIST/bin/ntfs-3g"
cp libntfs-3g/.libs/libntfs-3g.91.dylib "$DIST/lib/"
install_name_tool -change "$(otool -L "$DIST/bin/ntfs-3g" | awk '/libntfs-3g/{print $1}')" \
    "$DIST/lib/libntfs-3g.91.dylib" "$DIST/bin/ntfs-3g"
echo "✅ ntfs-3g（OpenNTFS 补丁版）已构建到 $DIST"
