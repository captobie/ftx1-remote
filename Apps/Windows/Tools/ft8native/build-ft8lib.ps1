# Builds ft8lib.dll (x64) from the vendored ft8_lib (Sources/CFT8Lib, MIT +
# kissfft BSD-3) plus ft8win.c, into FTX1RemoteWindows/Vendor/ft8/. Needs
# Visual Studio's C++ build tools. The DLL is committed (like Vendor/hamlib),
# so only rerun this when Sources/CFT8Lib or ft8win.c changes.
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = (Resolve-Path (Join-Path $here '..\..\..\..')).Path
$src = Join-Path $repo 'Sources\CFT8Lib'
$out = Join-Path $repo 'Apps\Windows\FTX1RemoteWindows\Vendor\ft8'
$obj = Join-Path $env:TEMP 'ft8lib-build'

$vcvars = Get-ChildItem (Join-Path $env:ProgramFiles 'Microsoft Visual Studio') -Recurse -Filter vcvars64.bat -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $vcvars) { throw 'Visual Studio C++ build tools (vcvars64.bat) not found' }

New-Item -ItemType Directory -Force $out, $obj | Out-Null
$sources = @(
    'ft8\constants.c', 'ft8\crc.c', 'ft8\ldpc.c', 'ft8\message.c', 'ft8\text.c',
    'fft\kiss_fft.c', 'fft\kiss_fftr.c'
) | ForEach-Object { Join-Path $src $_ }
# MSVC has no variable-length arrays, which monitor.c uses for two scratch
# buffers: build a patched copy (alloca) instead of editing the vendored file.
$monitor = Get-Content (Join-Path $src 'common\monitor.c') -Raw
$monitor = $monitor.Replace('kiss_fft_scalar timedata[me->nfft];', 'kiss_fft_scalar* timedata = (kiss_fft_scalar*)_alloca(sizeof(kiss_fft_scalar) * me->nfft);')
$monitor = $monitor.Replace('kiss_fft_cpx freqdata[me->nfft / 2 + 1];', 'kiss_fft_cpx* freqdata = (kiss_fft_cpx*)_alloca(sizeof(kiss_fft_cpx) * (me->nfft / 2 + 1));')
if ($monitor -notmatch '_alloca') { throw 'monitor.c no longer matches the expected scratch buffers' }
$patched = Join-Path $obj 'monitor_msvc.c'
Set-Content $patched ("#include <malloc.h>`r`n" + $monitor)
$sources += $patched
$decode = Get-Content (Join-Path $src 'ft8\decode.c') -Raw
$decode = $decode.Replace('float s2[n_tones];', 'float* s2 = (float*)_alloca(sizeof(float) * n_tones);')
if ($decode -notmatch '_alloca') { throw 'decode.c no longer matches the expected scratch buffer' }
$patchedDecode = Join-Path $obj 'decode_msvc.c'
Set-Content $patchedDecode ("#include <malloc.h>`r`n" + $decode)
$sources += $patchedDecode
$sources += Join-Path $here 'ft8win.c'
$srcArgs = ($sources | ForEach-Object { '"' + $_ + '"' }) -join ' '

# Forward slash after the object directory: a trailing backslash would
# escape the closing quote.
$objDir = ($obj -replace '\\', '/') + '/'
$config = Join-Path $here 'ft8win_config.h'
$dll = Join-Path $out 'ft8lib.dll'
$bat = Join-Path $obj 'build.bat'
Set-Content $bat @(
    '@echo off',
    ('call "' + $vcvars + '" >nul'),
    ('cl /nologo /O2 /LD /MT /W0 /FI"' + $config + '" /I"' + $src + '" /I"' + (Join-Path $src 'common') + '" /I"' + (Join-Path $src 'ft8') + '" ' + $srcArgs + ' /Fo"' + $objDir + '" /Fe"' + $dll + '"')
)
cmd /c ('"' + $bat + '"')
if ($LASTEXITCODE -ne 0) { throw "cl failed ($LASTEXITCODE)" }
Remove-Item (Join-Path $out 'ft8lib.lib'), (Join-Path $out 'ft8lib.exp') -ErrorAction SilentlyContinue
Copy-Item (Join-Path $src 'LICENSE-ft8lib.txt') $out -Force
Copy-Item (Join-Path $src 'fft\LICENSE-kissfft.txt') $out -Force
Write-Host "Built $dll"
