#!/bin/bash

## Builds OpenSSL shared libraries for macOS and lays them out the way conanfile.py
## packages them: Macos/<arch>/<BuildType>/{include,lib}, where <arch> is the Conan arch
## name (x86_64, armv8). One Conan package per arch, matching the macos.<arch>.<build_type>
## profiles Montage resolves (one architecture per conan install, see macos-arch.pri).
##
## Prerequisites: Xcode command line tools (clang, install_name_tool, codesign, lipo) and perl.
## Both architectures build on either host; x86_64 is cross-compiled on Apple Silicon.
##
## Environment overrides:
##   SSL_VERSION     OpenSSL version (default 3.5.9)
##   ARCHS           space separated OpenSSL arches: x86_64 arm64 (default both)
##   BUILD_TYPES     space separated: Release Debug (default both)
##   SSL_SOURCE_DIR  folder holding an already downloaded openssl-<version>.tar.gz
##   SSL_SHA256      expected SHA-256 of the tarball; when empty, the published .sha256 is used
##   MACOS_MIN       deployment target (default 12.0, the Qt 6.8 floor in client-desktop.pri)
##   OUTPUT_ROOT     where Macos/ is written (default: this folder)
##   BUILD_DIR       scratch build folder (default: ./build/macos)
##
## Usage:
##   ./build_ssl_macos.sh
##   ARCHS=arm64 BUILD_TYPES=Release ./build_ssl_macos.sh

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSL_VERSION="${SSL_VERSION:-3.5.9}"
read -r -a archs <<< "${ARCHS:-x86_64 arm64}"
read -r -a build_types <<< "${BUILD_TYPES:-Release Debug}"
MACOS_MIN="${MACOS_MIN:-12.0}"
OUTPUT_ROOT="${OUTPUT_ROOT:-$SCRIPT_DIR}"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/build/macos}"

# OpenSSL reads openssl.cnf from OPENSSLDIR and loads engines/providers from under the
# prefix, so both must point to root-owned locations on the end user's machine
# (the OpenSSL default, /usr/local/ssl, is writable by any Homebrew user).
PREFIX="/Library/DisplayNote/OpenSSL"
OPENSSL_DIR="/Library/DisplayNote/SSL"

if [ -n "$SSL_SOURCE_DIR" ]; then
    SSL_SOURCE_DIR="$(cd "$SSL_SOURCE_DIR" && pwd)" || { echo "SSL_SOURCE_DIR not found"; exit 1; }
fi

get_ssl_target() {
    case $1 in
    x86_64) echo "darwin64-x86_64-cc" ;;
    arm64)  echo "darwin64-arm64-cc" ;;
    *)      echo "Unsupported arch $1" >&2; exit 1 ;;
    esac
}

get_conan_arch() {
    case $1 in
    arm64) echo "armv8" ;;
    *)     echo "$1" ;;
    esac
}

fetch_tarball() {
    local file_name="openssl-$SSL_VERSION.tar.gz"
    TARBALL="$BUILD_DIR/$file_name"

    if [ -n "$SSL_SOURCE_DIR" ] && [ -f "$SSL_SOURCE_DIR/$file_name" ]; then
        echo "Using local OpenSSL $SSL_SOURCE_DIR/$file_name"
        cp "$SSL_SOURCE_DIR/$file_name" "$TARBALL"
    else
        echo "Downloading OpenSSL $file_name"
        curl -sfL -o "$TARBALL" "https://www.openssl.org/source/$file_name" \
            || { echo "Downloading sources failed!"; exit 1; }
    fi

    local expected="$SSL_SHA256"
    if [ -z "$expected" ]; then
        expected="$(curl -sfL "https://www.openssl.org/source/$file_name.sha256" | awk '{print $1}')" \
            || { echo "Downloading $file_name.sha256 failed!"; exit 1; }
    fi
    local actual
    actual="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        echo "SHA-256 mismatch for $file_name: expected $expected, got $actual"
        exit 1
    fi
    echo "SHA-256 verified: $actual"
}

build() {
    local arch=$1 build_type=$2
    local work_dir="$BUILD_DIR/$arch/$build_type"
    local src_dir="$work_dir/openssl-$SSL_VERSION"
    local log_file="$work_dir/build_${arch}_${build_type}.log"

    rm -rf "$work_dir"
    mkdir -p "$work_dir"
    tar xf "$TARBALL" -C "$work_dir"

    local config_params=( "$(get_ssl_target "$arch")" shared no-tests
                          "--prefix=$PREFIX" "--openssldir=$OPENSSL_DIR"
                          "-mmacosx-version-min=$MACOS_MIN" )
    [ "$build_type" = "Debug" ] && config_params+=( --debug )

    echo "Building OpenSSL $SSL_VERSION $arch $build_type (log: $log_file)"
    (
        cd "$src_dir"
        # Configure reads these from the environment and would override the target's flags.
        unset CC CFLAGS CPPFLAGS LDFLAGS
        ./Configure "${config_params[@]}"
        make -j"$(sysctl -n hw.ncpu)" build_libs
    ) > "$log_file" 2>&1 || { tail -40 "$log_file"; echo "OpenSSL $arch $build_type build failed; see $log_file"; exit 1; }

    # Copy straight from the build tree instead of `make install_sw`, which would install
    # into $PREFIX and also bring the openssl binary and the engines.
    local out_dir="$OUTPUT_ROOT/Macos/$(get_conan_arch "$arch")/$build_type"
    rm -rf "$out_dir"
    mkdir -p "$out_dir/include/openssl" "$out_dir/lib"
    cp "$src_dir"/include/openssl/*.h "$out_dir/include/openssl/"

    local lib
    for lib in libcrypto libssl; do
        cp "$src_dir/$lib.3.dylib" "$out_dir/lib/"
        ln -s "$lib.3.dylib" "$out_dir/lib/$lib.dylib"
        # The build records $PREFIX/lib as install name; the app bundles the libs in
        # Contents/Frameworks, which Qt apps already have as LC_RPATH.
        install_name_tool -id "@rpath/$lib.3.dylib" "$out_dir/lib/$lib.3.dylib"
    done
    install_name_tool -change "$PREFIX/lib/libcrypto.3.dylib" "@rpath/libcrypto.3.dylib" \
        "$out_dir/lib/libssl.3.dylib"

    # install_name_tool invalidates the linker's ad-hoc signature, which arm64 refuses to
    # load; the app's own codesign replaces it when the bundle is signed.
    for lib in libcrypto libssl; do
        codesign --force --sign - "$out_dir/lib/$lib.3.dylib"
    done

    verify "$out_dir" "$arch"
    echo "OpenSSL $SSL_VERSION $arch $build_type -> $out_dir"
}

verify() {
    local out_dir=$1 arch=$2 lib
    for lib in libcrypto libssl; do
        local dylib="$out_dir/lib/$lib.3.dylib"
        [ "$(lipo -archs "$dylib")" = "$arch" ] || { echo "$dylib is not $arch"; exit 1; }
        if otool -L "$dylib" | grep -q "$PREFIX"; then
            echo "$dylib still references $PREFIX"
            exit 1
        fi
    done
}

mkdir -p "$BUILD_DIR"
fetch_tarball
for arch in "${archs[@]}"; do
    for build_type in "${build_types[@]}"; do
        build "$arch" "$build_type"
    done
done
