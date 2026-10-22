# Android OpenSSL support for Qt
OpenSSL scripts and binaries - supports Qt for Android apps.

In this repo you can find the prebuilt OpenSSL libs for Android, a QMake include project `.pri` file that can be used integrated with Qt projects, and a `.cmake` file for CMake based projects.

The following directories are available
* `ssl_3`: for Qt 6.5.0+.
* `ssl_1_1`: for Qt Qt 5.12.5+, 5.13.1+, 5.14.0+, 5.15.0+, Qt 6.x.x up to 6.4.x

## How to use it
### QMake based projects
To add OpenSSL to your QMake project, append the following to your `.pro` project file:

```
android: include(<path/to/android_openssl/openssl.pri)
```

### CMake based projects
To add OpenSSL to your CMake project, append the following to your project's `CMakeLists.txt` file:

```
if (ANDROID)
    FetchContent_Declare(
      android_openssl
      DOWNLOAD_EXTRACT_TIMESTAMP true
      URL https://github.com/KDAB/android_openssl/archive/refs/heads/master.zip
#      URL_HASH MD5=c97d6ad774fab16be63b0ab40f78d945 #optional
    )
    FetchContent_MakeAvailable(android_openssl)
    include(${android_openssl_SOURCE_DIR}/android_openssl.cmake)
endif()
```
or, if you cloned the repository into a subdirectory:

```
include(<path/to/android_openssl>/android_openssl.cmake)
```

Then

```
qt_add_executable(your_target_name ..)
qt_add_executable(your_second_target_name ..)

if (ANDROID)
    add_android_openssl_libraries(your_target_name your_second_target_name)
endif()

```

## Build Script

You may use `build_ssl.sh` to rebuild OpenSSL libraries. OpenSSL/NDK version
pairs are predefined in the script to ensure compatibility with specific Qt
versions. Make sure the NDK paths and versions match your setup before running
it.

### Build Prerequisites

The build script was tested against `bash` and `zsh` on Linux and macOS.

## Windows (Conan package)

`build_ssl_windows.ps1` builds the OpenSSL shared libraries for Windows x86_64
with MSVC and lays them out as `Windows/<Release|Debug>/{include,lib,bin}`,
which `conanfile.py` packages (`libssl-3-x64.dll`, `libcrypto-3-x64.dll`, their
`.pdb`s and the `libssl.lib` / `libcrypto.lib` import libraries).

Prerequisites: Visual Studio 2022 or newer with the MSVC 14.40 toolset (the one
CI uses; override with `-VcvarsVer`), Strawberry Perl and NASM on `PATH`.

```powershell
.\build_ssl_windows.ps1                       # OpenSSL 3.5.9, Release + Debug
conan export-pkg . OpenSSL/3.5.9@dn/stable -pr msvc19.x86_64.release
conan export-pkg . OpenSSL/3.5.9@dn/stable -pr msvc19.x86_64.debug
```

Export with the same `msvc19.x86_64.*` profiles the consumers (Montage, dnrtc)
use, so their binary lookup finds these packages.

## macOS (Conan package)

`build_ssl_macos.sh` builds the OpenSSL shared libraries for macOS x86_64 and
arm64 (x86_64 is cross-compiled on Apple Silicon) and lays them out as
`Macos/<x86_64|armv8>/<Release|Debug>/{include,lib}`, one Conan package per
architecture, which `conanfile.py` packages (`libssl.3.dylib`,
`libcrypto.3.dylib` and their unversioned symlinks). The dylibs use `@rpath`
install names, so an app finds them in `Contents/Frameworks`, and target
macOS 12.0, the Qt 6.8 floor.

Prerequisites: Xcode command line tools and perl.

```bash
./build_ssl_macos.sh                          # OpenSSL 3.5.9, x86_64 + arm64, Release + Debug
conan export-pkg . OpenSSL/3.5.9@dn/stable -pr macos.x86_64.release
conan export-pkg . OpenSSL/3.5.9@dn/stable -pr macos.x86_64.debug
conan export-pkg . OpenSSL/3.5.9@dn/stable -pr macos.arm64.release
conan export-pkg . OpenSSL/3.5.9@dn/stable -pr macos.arm64.debug
```

Export with the same `macos.<arch>.*` profiles the consumers (Montage, dnrtc)
use, so their binary lookup finds these packages.
