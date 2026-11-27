# Builds ftx1rade.dll (x64): FreeDV's RADE V1 receiver and transmitter for the
# Windows app's FreeDV window, into FTX1RemoteWindows/Vendor/rade/. The Windows
# counterpart of the Mac's Scripts/build-rade.sh, from the same pinned,
# sha256-checked sources and the same wrapper (Scripts/rade/ftx1_rade.{h,c}):
#   - rade_c (freedv/rade_c, BSD-2), V1 sources only; Scripts/rade/
#     rade_v2_stubs.c stands in for the V2 calls rade_api.c references.
#   - Opus at the commit rade_c pins (BSD-3), with DRED + OSCE (which build
#     FARGAN) and its model data, built with CMake.
#   - freedv-backend's end-of-over callsign code (BSD-2): rade_text.cpp and
#     ldpc_*.cpp, with Scripts/rade/ulog.h in place of its logger.
# Needs Visual Studio's C++ build tools including "C++ CMake tools for Windows"
# (cmake + ninja). Downloads go to releases/rade-sources/ (gitignored) and are
# reused. The DLL is committed (like Vendor/ft8), so only rerun this when the
# pins or Scripts/rade change. Keep the pins equal to build-rade.sh's.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$RadeCommit = '23c3746e488dd4825178b4abb857106a5f61a4e6'
$RadeSha = 'e2eb9e7973032a8abc37d465273c0232acd153cb42faf8a824129c4c8e11908e'
$OpusCommit = '940d4e5af64351ca8ba8390df3f555484c567fbb'
$OpusSha = '285c74f5130ee074f123aaad81cd52c2fc8db653ee130941afafe3ee0ae8cec2'
$OpusModelSha = '4ed9445b96698bad25d852e912b41495ddfa30c8dbc8a55f9cde5826ed793453'
$BackendCommit = '49006b029853061ca4e992f9632a51875aa3ecf1'
$BackendSha = 'd8d8e158f770c9dd26b870a40c6562affae9cd5cda7d87bb6ef21382470d7cc7'

$here = $PSScriptRoot
$repo = (Resolve-Path (Join-Path $here '..\..\..\..')).Path
$wrapper = Join-Path $repo 'Scripts\rade'
$cache = Join-Path $repo 'releases\rade-sources'
$out = Join-Path $repo 'Apps\Windows\FTX1RemoteWindows\Vendor\rade'
# Short, because Opus's object paths get long.
$work = Join-Path $env:TEMP 'ftx1-rade'
$tar = Join-Path $env:SystemRoot 'System32\tar.exe'

$vcvars = Get-ChildItem (Join-Path $env:ProgramFiles 'Microsoft Visual Studio') -Recurse -Filter vcvars64.bat -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $vcvars) { throw 'Visual Studio C++ build tools (vcvars64.bat) not found' }

function Get-Pinned([string]$url, [string]$name, [string]$sha) {
    $file = Join-Path $cache $name
    if (-not (Test-Path $file)) {
        Write-Host "==> Downloading $name"
        Invoke-WebRequest -Uri $url -OutFile "$file.part"
        Move-Item "$file.part" $file
    }
    $actual = (Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $sha) { throw "$name has sha256 $actual, expected $sha" }
    return $file
}

New-Item -ItemType Directory -Force $cache | Out-Null
$radeTar = Get-Pinned "https://github.com/freedv/rade_c/archive/$RadeCommit.tar.gz" "rade_c-$RadeCommit.tar.gz" $RadeSha
$opusTar = Get-Pinned "https://github.com/xiph/opus/archive/$OpusCommit.tar.gz" "opus-$OpusCommit.tar.gz" $OpusSha
$modelTar = Get-Pinned "https://media.xiph.org/opus/models/opus_data-$OpusModelSha.tar.gz" "opus_data-$OpusModelSha.tar.gz" $OpusModelSha
$backendTar = Get-Pinned "https://github.com/freedv/freedv-backend/archive/$BackendCommit.tar.gz" "freedv-backend-$BackendCommit.tar.gz" $BackendSha

if (Test-Path $work) { Remove-Item $work -Recurse -Force }
$rade = Join-Path $work 'rade'
$opus = Join-Path $work 'opus'
$backend = Join-Path $work 'backend'
$obj = Join-Path $work 'obj'
New-Item -ItemType Directory -Force $rade, $opus, $backend, $obj, $out | Out-Null

function Expand-Tar([string]$file, [string]$into, [int]$strip) {
    & $tar -xzf $file -C $into --strip-components $strip
    if ($LASTEXITCODE -ne 0) { throw "tar failed on $file" }
}
Write-Host '==> Unpacking'
Expand-Tar $radeTar $rade 1
Expand-Tar $opusTar $opus 1
Expand-Tar $modelTar $opus 0
Expand-Tar $backendTar $backend 1

# Run commands in a Visual Studio x64 environment.
function Invoke-Vc([string[]]$commands) {
    $bat = Join-Path $work 'step.bat'
    # vcvars64.bat looks for vswhere.exe on PATH.
    $lines = @('@echo off', ('set "PATH=%PATH%;' + ${env:ProgramFiles(x86)} + '\Microsoft Visual Studio\Installer"'), ('call "' + $vcvars + '" >nul'))
    foreach ($c in $commands) { $lines += $c; $lines += 'if errorlevel 1 exit /b 1' }
    Set-Content $bat $lines
    cmd /c ('"' + $bat + '"')
    if ($LASTEXITCODE -ne 0) { throw "build step failed ($LASTEXITCODE)" }
}

# rade_c's nnet.c patch (opus-nnet.c.diff): a larger convolution scratch limit.
# Its nnet.h patch only adds GCC visibility attributes for rade_c's own shared
# library, which a static Opus doesn't need.
$nnet = Join-Path $opus 'dnn\nnet.c'
$text = Get-Content $nnet -Raw
$patched = $text.Replace('#define MAX_CONV_INPUTS_ALL DRED_MAX_CONV_INPUTS', '#define MAX_CONV_INPUTS_ALL 2048')
if ($patched -eq $text) { throw 'dnn/nnet.c no longer matches rade_c''s patch' }
Set-Content $nnet $patched -NoNewline
Set-Content (Join-Path $opus 'package_version') 'PACKAGE_VERSION="1.5.2"'

Write-Host '==> Opus'
$opusBuild = Join-Path $work 'opus-build'
Invoke-Vc @(
    ('cmake -G Ninja -S "' + $opus + '" -B "' + $opusBuild + '" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DOPUS_STATIC_RUNTIME=ON -DOPUS_DRED=ON -DOPUS_OSCE=ON -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF -DBUILD_TESTING=OFF > "' + (Join-Path $work 'cmake.log') + '"'),
    ('cmake --build "' + $opusBuild + '" > "' + (Join-Path $work 'opus.log') + '"')
)
$opusLib = Join-Path $opusBuild 'opus.lib'
if (-not (Test-Path $opusLib)) { throw 'opus.lib was not built' }

Write-Host '==> rade_c + callsign + wrapper'
$radeSrc = Join-Path $rade 'src'
# rade_api.h writes __stdcall ahead of the return type, which MSVC rejects
# (GCC doesn't mind). rade_c is linked inside our DLL, whose exports come from
# ftx1rade.def, so drop the decoration in this temporary copy.
$api = Join-Path $radeSrc 'rade_api.h'
$text = Get-Content $api -Raw
$patched = $text.Replace('#define RADE_EXPORT __declspec(dllexport) __stdcall', '#define RADE_EXPORT')
if ($patched -eq $text) { throw 'rade_api.h no longer defines RADE_EXPORT as expected' }
Set-Content $api $patched -NoNewline
# rade_c's V1 library sources (its src/CMakeLists.txt minus the V2 lists).
$radeFiles = @('rade_api.c', 'rade_enc.c', 'rade_dec.c', 'rade_enc_data.c', 'rade_dec_data.c',
    'rade_dsp.c', 'rade_ofdm.c', 'rade_bpf.c', 'rade_acq.c', 'rade_tx.c', 'rade_rx.c') |
    ForEach-Object { Join-Path $radeSrc $_ }
# freedv-backend's sources include "../util/logging/ulog.h"; give them ours.
$textDir = Join-Path $work 'text\pipeline'
$logDir = Join-Path $work 'text\util\logging'
New-Item -ItemType Directory -Force $textDir, $logDir | Out-Null
Copy-Item (Join-Path $wrapper 'ulog.h') $logDir
foreach ($f in 'rade_text.cpp', 'ldpc_encode.cpp', 'ldpc_decode.cpp', 'rade_text.h', 'ldpc_encode.h', 'ldpc_decode.h', 'HRA_56_56.h') {
    Copy-Item (Join-Path $backend "src\pipeline\$f") $textDir
}
$textFiles = 'rade_text.cpp', 'ldpc_encode.cpp', 'ldpc_decode.cpp' | ForEach-Object { Join-Path $textDir $_ }
$cFiles = @($radeFiles) + @((Join-Path $wrapper 'ftx1_rade.c'), (Join-Path $wrapper 'rade_v2_stubs.c'))

$includes = ($radeSrc, (Join-Path $opus 'include'), (Join-Path $opus 'dnn'), (Join-Path $opus 'celt'), $opus, $textDir, $wrapper |
    ForEach-Object { '/I"' + $_ + '"' }) -join ' '
# Forward slash after the object directory: a trailing backslash would escape
# the closing quote.
$objDir = ($obj -replace '\\', '/') + '/'
$common = '/nologo /O2 /MT /W0 /DNDEBUG /DIS_BUILDING_RADE_API=1 /D_USE_MATH_DEFINES /c ' + $includes + ' /Fo"' + $objDir + '"'
$cArgs = ($cFiles | ForEach-Object { '"' + $_ + '"' }) -join ' '
$cppArgs = ($textFiles | ForEach-Object { '"' + $_ + '"' }) -join ' '
$dll = Join-Path $out 'ftx1rade.dll'
Invoke-Vc @(
    ('cl /std:c17 ' + $common + ' ' + $cArgs),
    ('cl /std:c++20 /EHsc ' + $common + ' ' + $cppArgs),
    ('link /nologo /DLL /OPT:REF /OPT:ICF /DEF:"' + (Join-Path $here 'ftx1rade.def') + '" /OUT:"' + $dll + '" /IMPLIB:"' + (Join-Path $work 'ftx1rade.lib') + '" "' + (Join-Path $obj '*.obj') + '" "' + $opusLib + '"')
)

Copy-Item (Join-Path $rade 'LICENSE') (Join-Path $out 'LICENSE-rade_c.txt') -Force
Copy-Item (Join-Path $opus 'COPYING') (Join-Path $out 'LICENSE-opus.txt') -Force
Copy-Item (Join-Path $backend 'LICENSE') (Join-Path $out 'LICENSE-freedv-backend.txt') -Force
Set-Content (Join-Path $out 'VERSIONS.txt') @(
    'Built by Apps/Windows/Tools/radenative/build-rade.ps1',
    "rade_c          $RadeCommit",
    "opus            $OpusCommit (model data $OpusModelSha)",
    "freedv-backend  $BackendCommit",
    'platform        Windows x64, MSVC, static CRT'
)
Remove-Item $work -Recurse -Force
Write-Host "Built $dll"
