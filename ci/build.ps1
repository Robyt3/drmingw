param (
    [ValidateSet('mingw64','mingw32')][string]$target = 'mingw64',
    [string]$buildRoot = 'build',
    [switch]$coverage = $false  # https://stackoverflow.com/q/5079413
)

# https://stackoverflow.com/a/48999101
Set-StrictMode -Version latest
$ErrorActionPreference = "Stop"
function Exec {
    param(
        [Parameter(Position=0,Mandatory=1)][scriptblock]$cmd
    )
    Write-Host ("> " + $cmd.ToString().Trim())
    & $cmd
    if ($LastExitCode -ne 0) {
        throw
    }
}

$MINGW_64_URL = 'https://github.com/brechtsanders/winlibs_mingw/releases/download/12.2.0-14.0.6-10.0.0-msvcrt-r2/winlibs-x86_64-posix-seh-gcc-12.2.0-llvm-14.0.6-mingw-w64msvcrt-10.0.0-r2.7z'
$MINGW_32_URL = 'https://github.com/brechtsanders/winlibs_mingw/releases/download/12.2.0-14.0.6-10.0.0-msvcrt-r2/winlibs-i686-posix-dwarf-gcc-12.2.0-llvm-14.0.6-mingw-w64msvcrt-10.0.0-r2.7z'
$MINGW_64_SUM = 'c0dd9f2113a151dd2fe3dce8ceb30df90120fab4537349d7c0ee22e9ff4fe3bc'
$MINGW_32_SUM = '80ab3fb4b65870509f968e07e44f90d216eaf130fe9eb320b7a98285a84a0d2e'

$DBGHELP_64_URL = 'https://gist.githubusercontent.com/jrfonseca/55a9a0e0e228ad841032df1624da5e27/raw/8b5f0a1578be701128f09f886f9636389ae60268/dbghelp-win64.7z'
$DBGHELP_32_URL = 'https://gist.githubusercontent.com/jrfonseca/55a9a0e0e228ad841032df1624da5e27/raw/8b5f0a1578be701128f09f886f9636389ae60268/dbghelp-win32.7z'
$DBGHELP_64_SUM = '9bdc77e09a9ebdc8f810c46ed2b1171c048d6ebbe1b9ea1f927bfac66220dae5'
$DBGHELP_32_SUM = 'dfdf39857b76533adb0bffd9ef9d1bc7516280f810ecea6dd5c1b5ca97809706'

#
# Download and extract MinGW-w64 toolchain
#
New-Item -ItemType Directory -Force -Path downloads | Out-Null
if ($target -eq 'mingw64') {
    $MINGW_URL = $MINGW_64_URL
    $MINGW_SUM = $MINGW_64_SUM
    $DBGHELP_URL = $DBGHELP_64_URL
    $DBGHELP_SUM = $DBGHELP_64_SUM
} else {
    $MINGW_URL = $MINGW_32_URL
    $MINGW_SUM = $MINGW_32_SUM
    $DBGHELP_URL = $DBGHELP_32_URL
    $DBGHELP_SUM = $DBGHELP_32_SUM
}
$MINGW_ARCHIVE = Split-Path -leaf $MINGW_URL
$MINGW_ARCHIVE = "downloads\$MINGW_ARCHIVE"
if (!(Test-Path $MINGW_ARCHIVE -PathType Leaf)) {
    Write-Host "Downloading $MINGW_URL ..."
    Invoke-WebRequest -Uri $MINGW_URL -OutFile $MINGW_ARCHIVE -UserAgent NativeHost
    $hash = (Get-FileHash $MINGW_ARCHIVE -Algorithm SHA256).Hash
    if ($hash -ne $MINGW_SUM) {
        echo "error: ${MINGW_ARCHIVE}: wrong hash: ${hash}"
        exit 1
    }
}
New-Item -ItemType Directory -Force -Path "$buildRoot\toolchain" | Out-Null
$toolchain = "$buildRoot\toolchain\$target"
$toolchain = [System.IO.Path]::GetFullPath($toolchain)
if (!(Test-Path $toolchain -PathType Container)) {
    Write-Host "Extracting $MINGW_ARCHIVE to $toolchain ..."
    Exec { 7z x -y "-o$buildRoot\toolchain" $MINGW_ARCHIVE | Out-Null }
}
$Env:Path = "$toolchain\bin;$Env:Path"
(Get-Command 'g++.exe').Source
Exec { g++ --version }

$DBGHELP_ARCHIVE = "downloads\dbghelp-$target.7z"
$DBGHELP_DIR = "downloads\dbghelp\$target"
if (!(Test-Path $DBGHELP_DIR -PathType Container)) {
    if (!(Test-Path $DBGHELP_ARCHIVE -PathType Leaf)) {
        Invoke-WebRequest -Uri $DBGHELP_URL -OutFile $DBGHELP_ARCHIVE -UserAgent NativeHost
        $hash = (Get-FileHash $DBGHELP_ARCHIVE -Algorithm SHA256).Hash
        if ($hash -ne $DBGHELP_SUM) {
            echo "error: ${DBGHELP_ARCHIVE}: wrong hash: ${hash}"
            exit 1
        }
    }
    Exec { 7z x -y "-o$DBGHELP_DIR" $DBGHELP_ARCHIVE | Out-Null }
}


#
# Setup environment
#
$cwd = Get-Location
try {
    Get-Command python.exe -CommandType Application | Out-Null
} catch [System.Management.Automation.CommandNotFoundException] {
    $Env:Path = "${Env:ProgramFiles(x86)}\Microsoft Visual Studio\Shared\Python37_64;$Env:Path"
}
Exec { python --version }

try {
    Get-Command ninja.exe -CommandType Application | Out-Null
    Exec { ninja --version }
    $generator = "Ninja"
} catch [System.Management.Automation.CommandNotFoundException] {
    Exec { mingw32-make --version }
    $generator = "MinGW Makefiles"
    $Env:MAKEFLAGS = "-j${Env:NUMBER_OF_PROCESSORS}"
}

Exec { cmake --version }

(Get-Item "$DBGHELP_DIR\dbghelp.dll").VersionInfo.FileVersion

#
# Configure
#
$CMAKE_BUILD_TYPE = 'Debug'
if ($Env:GITHUB_EVENT_NAME -eq "push" -And $Env:GITHUB_REF.StartsWith('refs/tags/')) {
    $CMAKE_BUILD_TYPE = 'Release'
    $coverage = $false
}
$buildDir = "$buildRoot\$target"
Exec { cmake "-S." "-B$buildDir" -G $generator "-DCMAKE_BUILD_TYPE=$CMAKE_BUILD_TYPE" "-DENABLE_COVERAGE=$coverage" "-DWINDBG_DIR=$DBGHELP_DIR" }

#
# Build
#
Exec { cmake --build $buildDir --use-stderr --target all }

#
# Test
#
$Env:Path = "$DBGHELP_DIR;$Env:Path"
$Env:CTEST_OUTPUT_ON_FAILURE = '1'
Exec { cmake --build $buildDir --use-stderr --target test }

# MinGW GCC
Exec { cmake "-S" tests\apps "-B" "$buildRoot\apps\$target" -G $generator "-DCMAKE_BUILD_TYPE=Debug" }
Exec { cmake --build "$buildRoot\apps\$target" }
# MinGW Clang
Exec { cmake "-S" tests\apps "-B" "$buildRoot\apps\$target-clang" -G $generator "-DCMAKE_BUILD_TYPE=Debug" "-DCMAKE_C_COMPILER=clang" "-DCMAKE_CXX_COMPILER=clang++" "-DCMAKE_C_FLAGS_DEBUG=-g" "-DCMAKE_CXX_FLAGS_DEBUG=-g" }
Exec { cmake --build "$buildRoot\apps\$target-clang" }
# MSVC 32-bits
Exec { cmake "-S" tests\apps "-B" "$buildRoot\apps\msvc32" -G "Visual Studio 17 2022" -A Win32 }
Exec { cmake --build "$buildRoot\apps\msvc32" --config Debug "--" /verbosity:minimal /maxcpucount }
if ($target -eq "mingw64") {
    # MSVC 64-bits
    Exec { cmake -Stests\apps "-B$buildRoot\apps\msvc64" -G "Visual Studio 17 2022" -A x64 }
    Exec { cmake --build "$buildRoot\apps\msvc64" --config Debug "--" /verbosity:minimal /maxcpucount }

    Exec { python tests\apps\test.py $buildDir\bin\catchsegv.exe "$buildRoot\apps\$target" "$buildRoot\apps\$target-clang" "$buildRoot\apps\msvc32\Debug" "$buildRoot\apps\msvc64\Debug" }
} else {
    Exec { python tests\apps\test.py $buildDir\bin\catchsegv.exe "$buildRoot\apps\$target" "$buildRoot\apps\$target-clang" "$buildRoot\apps\msvc32\Debug" }
}

#
# Code coverage
#
if ($coverage) {
    Exec { gcov --version }
    if (Test-Path Env:CODECOV_TOKEN) {
        Exec { python -m gcovr --exclude-unreachable-branches --exclude-throw-branches --object-directory $buildDir --xml -o "cobertura.xml" }
        Exec { python -m codecov --file cobertura.xml -X gcov search }
    } else {
        Exec { python -m gcovr --exclude-unreachable-branches --exclude-throw-branches --object-directory $buildDir --html-details -o "$buildDir\coverage.html" }
    }
}

#
# Package
#
if (Test-Path Env:CI) {
    Exec { cmake --build $buildDir --use-stderr --target package }
}
