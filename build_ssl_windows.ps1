## Builds OpenSSL shared libraries for Windows x86_64 (MSVC) and lays them out the
## way conanfile.py packages them: Windows/<BuildType>/{include,lib,bin}.
##
## Prerequisites:
## - Visual Studio 2022 or newer with the MSVC toolset given by -VcvarsVer installed
##   (default 14.40, the toolset CI's agent-pool-windows2022-vmss resolves).
## - Strawberry Perl (a native Windows perl; Git's MSYS perl cannot drive the VC build).
## - NASM on PATH, unless -NoAsm is given.
##
## Usage:
##   .\build_ssl_windows.ps1                               # 3.5.9, Release + Debug
##   .\build_ssl_windows.ps1 -BuildTypes Release
##   .\build_ssl_windows.ps1 -SourceDir C:\src             # use an already downloaded tarball
##   .\build_ssl_windows.ps1 -Sha256 <hash>                # pin the tarball hash

[CmdletBinding()]
param(
    [string]   $Version    = "3.5.9",
    [string[]] $BuildTypes = @("Release", "Debug"),
    [string]   $OutputRoot = $PSScriptRoot,
    [string]   $BuildDir   = (Join-Path $PSScriptRoot "build\windows"),
    # Folder holding an already downloaded and verified openssl-<version>.tar.gz.
    [string]   $SourceDir  = "",
    # Expected SHA-256 of the tarball. When empty, the .sha256 published next to it is used.
    [string]   $Sha256     = "",
    [string]   $VcvarsVer  = "14.40",
    # OpenSSL reads openssl.cnf from OPENSSLDIR and loads engines/providers from under
    # the prefix, so both must point to admin-only locations on the end user's machine.
    [string]   $Prefix     = "C:\Program Files\DisplayNote\OpenSSL",
    [string]   $OpenSslDir = "C:\Program Files\Common Files\DisplayNote\SSL",
    [switch]   $NoAsm
)

$ErrorActionPreference = "Stop"

function Get-VcvarsPath
{
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { throw "vswhere.exe not found; install Visual Studio 2022 or newer" }
    $vsPaths = @(& $vswhere -all -sort -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
    if (-not $vsPaths) { throw "No Visual Studio installation with the x64 C++ tools found" }

    # -latest could pick a newer Visual Studio that lacks the requested toolset, so use the
    # newest installation that actually has VC\Tools\MSVC\<VcvarsVer>.*
    foreach ($vsPath in $vsPaths)
    {
        $vcvars = Join-Path $vsPath "VC\Auxiliary\Build\vcvars64.bat"
        $toolsets = Get-ChildItem (Join-Path $vsPath "VC\Tools\MSVC") -Directory -Filter "$VcvarsVer*" -ErrorAction SilentlyContinue
        if ($toolsets -and (Test-Path $vcvars))
        {
            Write-Host "Using MSVC $($toolsets[-1].Name) from $vsPath"
            return $vcvars
        }
    }
    throw "No Visual Studio installation has the MSVC $VcvarsVer toolset (checked: $($vsPaths -join ', ')); install it or pass -VcvarsVer"
}

function Assert-Prerequisites
{
    $perl = Get-Command perl -ErrorAction SilentlyContinue
    if (-not $perl) { throw "perl not found on PATH; install Strawberry Perl" }
    $perlOs = & perl -e 'print $^O'
    if ($perlOs -ne "MSWin32") { throw "perl at $($perl.Source) reports '$perlOs'; a native Windows perl (Strawberry Perl) is required" }

    if (-not $NoAsm -and -not (Get-Command nasm -ErrorAction SilentlyContinue))
    {
        throw "nasm not found on PATH; install NASM or pass -NoAsm"
    }
}

function Get-Tarball([string] $downloadDir)
{
    $fileName = "openssl-$Version.tar.gz"
    $tarball = Join-Path $downloadDir $fileName

    if ($SourceDir -and (Test-Path (Join-Path $SourceDir $fileName)))
    {
        $localTarball = (Resolve-Path (Join-Path $SourceDir $fileName)).Path
        Write-Host "Using local OpenSSL $localTarball"
        if ($localTarball -ne (Resolve-Path -LiteralPath $downloadDir).Path + "\$fileName")
        {
            Copy-Item $localTarball $tarball
        }
    }
    else
    {
        Write-Host "Downloading OpenSSL $fileName"
        Invoke-WebRequest -UseBasicParsing -Uri "https://www.openssl.org/source/$fileName" -OutFile $tarball
    }

    $expected = $Sha256
    if (-not $expected)
    {
        $shaFile = "$tarball.sha256"
        Invoke-WebRequest -UseBasicParsing -Uri "https://www.openssl.org/source/$fileName.sha256" -OutFile $shaFile
        $expected = ((Get-Content $shaFile -Raw).Trim() -split '\s+')[0]
    }
    $actual = (Get-FileHash -Algorithm SHA256 $tarball).Hash
    if ($actual -ne $expected.ToUpperInvariant()) { throw "SHA-256 mismatch for ${fileName}: expected $expected, got $actual" }
    Write-Host "SHA-256 verified: $actual"
    return $tarball
}

function Invoke-Build([string] $vcvars, [string] $tarball, [string] $buildType)
{
    $workDir = Join-Path $BuildDir $buildType
    if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
    New-Item -ItemType Directory -Force $workDir | Out-Null

    # Windows ships bsdtar as tar.exe
    & tar -xf $tarball -C $workDir
    if ($LASTEXITCODE -ne 0) { throw "Extracting $tarball failed" }
    $srcDir = Join-Path $workDir "openssl-$Version"

    $configureArgs = @("VC-WIN64A", "shared", "no-tests", "`"--prefix=%DN_OSSL_PREFIX%`"", "`"--openssldir=%DN_OSSL_DIR%`"")
    if ($buildType -eq "Debug") { $configureArgs += "--debug" }
    if ($NoAsm) { $configureArgs += "no-asm" }

    # Run configure + build inside one cmd session so the vcvars environment applies.
    # Paths reach the batch file through inherited environment variables, so the file itself
    # stays ASCII and checkouts under non-ASCII paths (e.g. a user folder with accents) keep working.
    $logFile = Join-Path $workDir "build_$buildType.log"
    $script = Join-Path $workDir "build.cmd"
    @(
        "@echo off",
        "call `"%DN_OSSL_VCVARS%`" -vcvars_ver=$VcvarsVer || exit /b 1",
        "cd /d `"%DN_OSSL_SRC%`" || exit /b 1",
        "perl Configure $($configureArgs -join ' ') || exit /b 1",
        "nmake build_libs || exit /b 1"
    ) | Set-Content -Encoding ascii $script

    $env:DN_OSSL_VCVARS = $vcvars
    $env:DN_OSSL_SRC    = $srcDir
    $env:DN_OSSL_PREFIX = $Prefix
    $env:DN_OSSL_DIR    = $OpenSslDir
    Write-Host "Building OpenSSL $Version $buildType (log: $logFile)"
    try
    {
        & cmd /c "`"$script`" > `"$logFile`" 2>&1"
    }
    finally
    {
        Remove-Item Env:DN_OSSL_VCVARS, Env:DN_OSSL_SRC, Env:DN_OSSL_PREFIX, Env:DN_OSSL_DIR -ErrorAction SilentlyContinue
    }
    if ($LASTEXITCODE -ne 0)
    {
        Get-Content $logFile -Tail 40
        throw "OpenSSL $buildType build failed; see $logFile"
    }

    # Copy straight from the build tree instead of `nmake install_sw`, which would
    # install into $Prefix and also bring openssl.exe and the engines.
    $outDir = Join-Path $OutputRoot "Windows\$buildType"
    if (Test-Path $outDir) { Remove-Item -Recurse -Force $outDir }
    New-Item -ItemType Directory -Force (Join-Path $outDir "include\openssl"), (Join-Path $outDir "lib"), (Join-Path $outDir "bin") | Out-Null

    Copy-Item (Join-Path $srcDir "include\openssl\*.h") (Join-Path $outDir "include\openssl")
    # The build defines OPENSSL_USE_APPLINK: an MSVC app that passes FILE* to the DLL
    # (e.g. ERR_print_errors_fp) must compile <openssl/applink.c>, as install_sw ships it.
    Copy-Item (Join-Path $srcDir "ms\applink.c") (Join-Path $outDir "include\openssl")
    Copy-Item (Join-Path $srcDir "libcrypto.lib"), (Join-Path $srcDir "libssl.lib") (Join-Path $outDir "lib")
    foreach ($lib in @("libcrypto-3-x64", "libssl-3-x64"))
    {
        Copy-Item (Join-Path $srcDir "$lib.dll") (Join-Path $outDir "bin")
        Copy-Item (Join-Path $srcDir "$lib.pdb") (Join-Path $outDir "bin")
    }
    Write-Host "OpenSSL $Version $buildType -> $outDir"
}

Assert-Prerequisites
$vcvars = Get-VcvarsPath
New-Item -ItemType Directory -Force $BuildDir | Out-Null
$tarball = Get-Tarball $BuildDir
foreach ($buildType in $BuildTypes)
{
    Invoke-Build $vcvars $tarball $buildType
}
