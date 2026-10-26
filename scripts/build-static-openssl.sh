#!/bin/bash
# build-static-openssl.sh — build static OpenSSL (libssl.a + libcrypto.a) for macOS.
#
# Usage: build-static-openssl.sh <arm64|x86_64> <prefix>
#
# Used by the macOS SSL-variant build (SSL_VARIANT=staticssl in build.sh) so that
# llama-server carries OpenSSL inside the binary instead of linking Homebrew's
# dylibs. Building from the pinned source tarball (not brew) also gives a real
# x86_64 static OpenSSL for the cross-compiled macos-x64 variant.
set -euo pipefail

ARCH="${1:?arch: arm64|x86_64}"
PREFIX="${2:?prefix}"
VERSION="3.4.1"
SHA256="002a2d6b30b58bf4bea46c43bdd96365aaf8daa6c428782aa4feee06da197df3"

case "$ARCH" in
    arm64)  TARGET="darwin64-arm64-cc" ;;
    x86_64) TARGET="darwin64-x86_64-cc" ;;
    *) echo "unsupported arch $ARCH"; exit 1 ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
curl -fsSL -o "$WORK/openssl.tgz" \
    "https://github.com/openssl/openssl/releases/download/openssl-${VERSION}/openssl-${VERSION}.tar.gz"
echo "${SHA256}  $WORK/openssl.tgz" | shasum -a 256 -c -
tar -xzf "$WORK/openssl.tgz" -C "$WORK"
cd "$WORK/openssl-${VERSION}"
./Configure "$TARGET" no-shared no-tests no-apps --prefix="$PREFIX" --libdir=lib
make -j"$(sysctl -n hw.ncpu)" build_libs
make install_dev
ls -l "$PREFIX/lib/libssl.a" "$PREFIX/lib/libcrypto.a"
