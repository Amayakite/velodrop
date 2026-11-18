#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=1.37.0
archive="aria2-$version.tar.xz"
hash=60a420ad7085eb616cb6e2bdf0a7206d68ff3d37fb5a956dc44242eb2f79b66b
build="$(pwd)/.build/engine-$(uname -m)"
mkdir -p "$build"
cd "$build"
if [[ ! -f "$archive" ]]; then
    curl --fail --location --retry 2 --output "$archive.tmp" "https://github.com/aria2/aria2/releases/download/release-$version/$archive"
    mv "$archive.tmp" "$archive"
fi
printf '%s  %s\n' "$hash" "$archive" | shasum -a 256 -c -
if [[ ! -x aria2c ]]; then
    tar -xf "$archive"
    cd "aria2-$version"
    export MACOSX_DEPLOYMENT_TARGET=14.0
    ./configure --with-appletls --without-openssl --without-gnutls --without-libcares \
        --without-sqlite3 --without-libssh2 --without-libxml2 --without-libexpat \
        --disable-bittorrent --disable-metalink --disable-nls > ../configure.log 2>&1
    make -j "$(sysctl -n hw.logicalcpu)" > ../make.log 2>&1
    cp src/aria2c ../aria2c
    strip -x ../aria2c
fi
"$build/aria2c" --version | head -8
