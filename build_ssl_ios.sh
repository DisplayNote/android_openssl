#!/bin/bash

## Builds the OpenSSL static libraries for iOS arm64 (device) with Xcode and lays
## them out the way conanfile.py packages them: iOS/<Release|Debug>/{include,lib}.
##
## Prerequisites: macOS with Xcode (xcrun and the iphoneos SDK) and perl.
##
## Set SSL_VERSION to build another OpenSSL release (default 3.5.9).
## Set BUILD_TYPES (space separated) to build only some of "Release Debug".
## Set IOS_MIN_VERSION to change the minimum iOS version (default 16.0, the
## QMAKE_IOS_DEPLOYMENT_TARGET of Qt 6.8).
## Set BUILD_DIR and OUTPUT_ROOT to use custom build and output paths.
## Set SSL_SOURCE_DIR to a folder holding an already downloaded and verified
## openssl-<version>.tar.gz file to skip the download.
## Set SSL_SHA256 to pin the tarball hash. When empty, the .sha256 published next
## to the tarball (or found next to it in SSL_SOURCE_DIR) is used.

set -eo pipefail

[ -n "$SSL_VERSION" ] || SSL_VERSION="3.5.9"
[ -n "$IOS_MIN_VERSION" ] || IOS_MIN_VERSION="16.0"
[ -n "$OUTPUT_ROOT" ] || OUTPUT_ROOT="$(pwd)"
[ -n "$BUILD_DIR" ] || BUILD_DIR="$(pwd)/build/ios"

build_types=("Release" "Debug")
[ -n "$BUILD_TYPES" ] && read -r -a build_types <<< "$BUILD_TYPES"

# Make the paths absolute: they are used after changing into the build directories.
mkdir -p "$OUTPUT_ROOT" "$BUILD_DIR"
OUTPUT_ROOT="$(cd "$OUTPUT_ROOT" && pwd)"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
if [ -n "$SSL_SOURCE_DIR" ]; then
    SSL_SOURCE_DIR="$(cd "$SSL_SOURCE_DIR" && pwd)" || { echo "SSL_SOURCE_DIR not found"; exit 1; }
fi

ssl_filename="openssl-$SSL_VERSION.tar.gz"
ssl_url="https://github.com/openssl/openssl/releases/download/openssl-$SSL_VERSION/$ssl_filename"

get_tarball() {
    tarball="$BUILD_DIR/$ssl_filename"

    if [ -n "$SSL_SOURCE_DIR" ] && [ -f "$SSL_SOURCE_DIR/$ssl_filename" ]; then
        echo "Using local OpenSSL $SSL_SOURCE_DIR/$ssl_filename"
        # SSL_SOURCE_DIR may be BUILD_DIR itself, possibly through another path (e.g. a symlink)
        if [ ! "$SSL_SOURCE_DIR/$ssl_filename" -ef "$tarball" ]; then
            cp "$SSL_SOURCE_DIR/$ssl_filename" "$tarball"
            if [ -f "$SSL_SOURCE_DIR/$ssl_filename.sha256" ]; then
                cp "$SSL_SOURCE_DIR/$ssl_filename.sha256" "$tarball.sha256"
            fi
        fi
    else
        echo "Downloading OpenSSL $ssl_filename"
        curl -sfL -o "$tarball" "$ssl_url" || { echo "Downloading sources failed!"; exit 1; }
    fi

    expected="$SSL_SHA256"
    if [ -z "$expected" ]; then
        [ -f "$tarball.sha256" ] || curl -sfL -o "$tarball.sha256" "$ssl_url.sha256" \
            || { echo "Downloading the SHA-256 failed!"; exit 1; }
        expected="$(awk '{ print $1 }' "$tarball.sha256")"
    fi
    actual="$(shasum -a 256 "$tarball" | awk '{ print $1 }')"
    if [ "$actual" != "$expected" ]; then
        echo "SHA-256 mismatch for $ssl_filename: expected $expected, got $actual"
        exit 1
    fi
    echo "SHA-256 OK: $actual"
}

configure_ssl() {
    build_type=$1
    log_file=$2

    # ios64-xcrun hard-codes -mios-version-min=7.0.0; inherit it with our minimum instead.
    cat > dn-ios.conf <<EOF
my %targets = (
    "ios64-dn" => {
        inherit_from => [ "ios64-xcrun" ],
        cflags       => "-arch arm64 -mios-version-min=$IOS_MIN_VERSION -fno-common",
    },
);
EOF

    config_params=( "ios64-dn" "--config=dn-ios.conf" "no-shared" "no-tests" )
    if [ "$build_type" = "Debug" ]; then
        config_params+=( "--debug" )
    fi

    echo "Configuring OpenSSL $SSL_VERSION for iOS arm64 ($build_type, iOS $IOS_MIN_VERSION+)"
    echo "Configure parameters: ${config_params[*]}"
    ./Configure "${config_params[@]}" > "$log_file" 2>&1 || { tail -n 40 "$log_file"; exit 1; }
}

build_ssl() {
    log_file=$1

    echo "Building..."
    make -j"$(sysctl -n hw.ncpu)" build_libs >> "$log_file" 2>&1 || { tail -n 40 "$log_file"; exit 1; }
}

copy_build_artefacts() {
    output_dir=$1

    rm -rf "$output_dir"
    mkdir -p "$output_dir/lib"
    cp libcrypto.a libssl.a "$output_dir/lib/"
    cp -a include "$output_dir/"

    # Clean include folder
    find "$output_dir/include" -name "*.in" -delete
    find "$output_dir/include" -name "*.def" -delete
}

xcrun --sdk iphoneos --show-sdk-path > /dev/null || { echo "The iphoneos SDK was not found; install Xcode"; exit 1; }

get_tarball

for build_type in "${build_types[@]}"; do
    work_dir="$BUILD_DIR/$build_type"
    rm -rf "$work_dir"
    mkdir -p "$work_dir"
    pushd "$work_dir" > /dev/null

    echo "Extracting OpenSSL $SSL_VERSION under $work_dir"
    tar xf "$BUILD_DIR/$ssl_filename"
    pushd "openssl-$SSL_VERSION" > /dev/null

    log_file="$work_dir/build_ios_arm64_${SSL_VERSION}.log"
    configure_ssl "$build_type" "$log_file"
    build_ssl "$log_file"
    copy_build_artefacts "$OUTPUT_ROOT/iOS/$build_type"

    popd > /dev/null
    popd > /dev/null
done
