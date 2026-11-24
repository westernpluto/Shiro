#!/usr/bin/env bash
# Cross-compiles chiaki-ng's protocol library and all of its dependencies
# (OpenSSL, Opus, libevent, curl, json-c, miniupnpc, nanopb, jerasure) for
# iOS arm64 and merges everything into one static library that the Xcode
# project links against.
#
# Output:
#   Vendor/Chiaki/include/   public chiaki headers (+ generated config.h)
#   Vendor/Chiaki/lib/libchiaki-ios.a
#
# Requirements (macOS host): Xcode, cmake, ninja, pkg-config, protoc, python3 + protobuf.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHIAKI_REF="${CHIAKI_REF:-v1.10.1}"
OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.4}"
OPUS_VERSION="${OPUS_VERSION:-1.5.2}"
LIBEVENT_VERSION="${LIBEVENT_VERSION:-2.1.12}"
MIN_IOS="${MIN_IOS:-17.0}"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

WORK="${WORK:-$ROOT/build/deps}"
SRC="$WORK/src"
PREFIX="$WORK/prefix"
OUT="$ROOT/Vendor/Chiaki"

mkdir -p "$SRC" "$PREFIX/lib" "$PREFIX/include" "$OUT"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
export SDKROOT="$SDK"
# Keep pkg-config away from Homebrew's macOS libraries.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
unset PKG_CONFIG_PATH || true

echo "==> SDK: $SDK"
echo "==> Prefix: $PREFIX"

COMMON_CMAKE=(
  -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_SYSTEM_NAME=iOS
  -DCMAKE_OSX_SYSROOT=iphoneos
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS"
  -DCMAKE_INSTALL_PREFIX="$PREFIX"
  -DCMAKE_PREFIX_PATH="$PREFIX"
  -DCMAKE_FIND_ROOT_PATH="$PREFIX;$SDK"
  -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
  -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local"
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  -DBUILD_SHARED_LIBS=OFF
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  "-DCMAKE_C_FLAGS=-O3 -fno-common"
)

fetch() { # url dest-dir
  local url="$1" dir="$2"
  if [ ! -d "$dir" ]; then
    echo "==> Fetching $url"
    mkdir -p "$dir.tmp"
    curl -fsSL --retry 5 --retry-delay 3 "$url" | tar xz -C "$dir.tmp" --strip-components 1
    mv "$dir.tmp" "$dir"
  fi
}

# ---------------------------------------------------------------- OpenSSL
if [ ! -f "$PREFIX/lib/libcrypto.a" ]; then
  fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" "$SRC/openssl"
  pushd "$SRC/openssl" >/dev/null
  ./Configure ios64-xcrun no-shared no-tests no-apps no-docs no-module no-engine no-async no-dso \
    --prefix="$PREFIX" --libdir=lib --openssldir="$PREFIX/ssl" "-mios-version-min=$MIN_IOS" -O3
  make -j"$JOBS" build_libs >/dev/null
  make install_dev >/dev/null
  popd >/dev/null
fi

# ---------------------------------------------------------------- Opus
if [ ! -f "$PREFIX/lib/libopus.a" ]; then
  fetch "https://downloads.xiph.org/releases/opus/opus-$OPUS_VERSION.tar.gz" "$SRC/opus"
  cmake -S "$SRC/opus" -B "$WORK/build-opus" "${COMMON_CMAKE[@]}" \
    -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF -DBUILD_TESTING=OFF \
    -DOPUS_INSTALL_PKG_CONFIG_MODULE=ON -DOPUS_INSTALL_CMAKE_CONFIG_MODULE=ON
  cmake --build "$WORK/build-opus" -j"$JOBS"
  cmake --install "$WORK/build-opus"
fi

# ---------------------------------------------------------------- libevent
if [ ! -f "$PREFIX/lib/libevent.a" ]; then
  fetch "https://github.com/libevent/libevent/releases/download/release-$LIBEVENT_VERSION-stable/libevent-$LIBEVENT_VERSION-stable.tar.gz" "$SRC/libevent"
  cmake -S "$SRC/libevent" -B "$WORK/build-libevent" "${COMMON_CMAKE[@]}" \
    -DEVENT__LIBRARY_TYPE=STATIC \
    -DEVENT__DISABLE_OPENSSL=ON -DEVENT__DISABLE_MBEDTLS=ON \
    -DEVENT__DISABLE_TESTS=ON -DEVENT__DISABLE_REGRESS=ON \
    -DEVENT__DISABLE_SAMPLES=ON -DEVENT__DISABLE_BENCHMARK=ON \
    -DEVENT__DISABLE_DEBUG_MODE=ON -DEVENT__DISABLE_THREAD_SUPPORT=OFF
  cmake --build "$WORK/build-libevent" -j"$JOBS"
  cmake --install "$WORK/build-libevent"
fi

# ---------------------------------------------------------------- chiaki-ng
if [ ! -d "$SRC/chiaki-ng" ]; then
  git clone --depth 1 --branch "$CHIAKI_REF" --recurse-submodules --shallow-submodules \
    https://github.com/chiaki-ng/chiaki-ng.git "$SRC/chiaki-ng"
fi

# Apply local patches (idempotent).
if [ -d "$ROOT/scripts/patches" ]; then
  for p in "$ROOT"/scripts/patches/*.patch; do
    [ -e "$p" ] || continue
    if git -C "$SRC/chiaki-ng" apply --check "$p" 2>/dev/null; then
      echo "==> Applying $(basename "$p")"
      git -C "$SRC/chiaki-ng" apply "$p"
    fi
  done
fi

PROTOC_BIN="${PROTOC_BIN:-$(command -v protoc)}"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3)}"

cmake -S "$SRC/chiaki-ng" -B "$WORK/build-chiaki" "${COMMON_CMAKE[@]}" \
  -DCHIAKI_ENABLE_TESTS=OFF -DCHIAKI_ENABLE_CLI=OFF -DCHIAKI_ENABLE_GUI=OFF \
  -DCHIAKI_ENABLE_ANDROID=OFF -DCHIAKI_ENABLE_BOREALIS=OFF \
  -DCHIAKI_ENABLE_SETSU=OFF -DCHIAKI_ENABLE_STEAMDECK_NATIVE=OFF \
  -DCHIAKI_ENABLE_FFMPEG_DECODER=OFF -DCHIAKI_ENABLE_PI_DECODER=OFF \
  -DCHIAKI_ENABLE_STEAM_SHORTCUT=OFF -DCHIAKI_ENABLE_SPEEX=OFF \
  -DCHIAKI_GUI_ENABLE_SDL_GAMECONTROLLER=OFF \
  -DCHIAKI_LIB_ENABLE_OPUS=ON -DCHIAKI_LIB_ENABLE_MBEDTLS=OFF \
  -DCHIAKI_LIB_JSONC_EXTERNAL_PROJECT=ON -DCHIAKI_LIB_MINIUPNPC_EXTERNAL_PROJECT=ON \
  -DCHIAKI_USE_SYSTEM_JERASURE=OFF -DCHIAKI_USE_SYSTEM_NANOPB=OFF -DCHIAKI_USE_SYSTEM_CURL=OFF \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS" \
  -DOPENSSL_ROOT_DIR="$PREFIX" -DOPENSSL_USE_STATIC_LIBS=TRUE \
  -DOPENSSL_INCLUDE_DIR="$PREFIX/include" \
  -DOPENSSL_CRYPTO_LIBRARY="$PREFIX/lib/libcrypto.a" \
  -DOPENSSL_SSL_LIBRARY="$PREFIX/lib/libssl.a" \
  -DOpus_INCLUDE_DIRS="$PREFIX/include" -DOpus_LIBRARIES="$PREFIX/lib/libopus.a" \
  -DCURL_USE_OPENSSL=ON -DCURL_USE_LIBPSL=OFF -DCURL_ZSTD=OFF -DCURL_BROTLI=OFF \
  -DCURL_ZLIB=OFF -DUSE_NGHTTP2=OFF -DUSE_LIBIDN2=OFF -DUSE_APPLE_IDN=OFF \
  -DCURL_USE_LIBSSH2=OFF -DCURL_USE_LIBSSH=OFF -DCURL_USE_GSSAPI=OFF -DCURL_DISABLE_LDAP=ON \
  -DCURL_CA_BUNDLE=none -DCURL_CA_PATH=none -DCURL_CA_FALLBACK=ON \
  -DCURL_USE_PKGCONFIG=OFF -DENABLE_CURL_MANUAL=OFF -DBUILD_LIBCURL_DOCS=OFF -DBUILD_MISC_DOCS=OFF \
  -DCMAKE_PROJECT_INCLUDE="$ROOT/scripts/ios-project-include.cmake" \
  -DPKG_CONFIG_EXECUTABLE="$(command -v pkg-config || command -v pkgconf)" \
  -DPROTOC="$PROTOC_BIN" -DPYTHON_EXECUTABLE="$PYTHON_BIN" -DPython3_EXECUTABLE="$PYTHON_BIN"

cmake --build "$WORK/build-chiaki" -j"$JOBS" --target chiaki-lib

# ---------------------------------------------------------------- merge
echo "==> Merging static libraries"
LIBS=()
while IFS= read -r f; do LIBS+=("$f"); done < <(find "$WORK/build-chiaki" -name '*.a' ! -name 'libcurlu.a' ! -name '*test*' | sort)
LIBS+=("$PREFIX/lib/libcrypto.a" "$PREFIX/lib/libssl.a" "$PREFIX/lib/libopus.a")
for f in "$PREFIX"/lib/libevent.a "$PREFIX"/lib/libevent_pthreads.a; do
  [ -f "$f" ] && LIBS+=("$f")
done
printf '   %s\n' "${LIBS[@]}"

rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include"
xcrun libtool -static -no_warning_for_no_symbols -o "$OUT/lib/libchiaki-ios.a" "${LIBS[@]}"

cp -R "$SRC/chiaki-ng/lib/include/chiaki" "$OUT/include/"
cp "$WORK/build-chiaki/lib/include/chiaki/config.h" "$OUT/include/chiaki/config.h"
# Decoders we do not build.
rm -f "$OUT/include/chiaki/ffmpegdecoder.h" "$OUT/include/chiaki/pidecoder.h"
echo "$CHIAKI_REF" > "$OUT/CHIAKI_VERSION"

echo "==> Done: $(du -h "$OUT/lib/libchiaki-ios.a" | cut -f1) $OUT/lib/libchiaki-ios.a"
