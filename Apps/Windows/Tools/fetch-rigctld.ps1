<#
.SYNOPSIS
  Vendors Hamlib's official Windows rigctld.exe into
  FTX1RemoteWindows/Vendor/hamlib/ (see Apps/Windows/README.md, "Bundled
  rigctld").

.DESCRIPTION
  Takes Hamlib's official Windows build zip (hamlib-w64-<version>.zip from
  https://github.com/Hamlib/Hamlib/releases), checks its SHA-256 against
  the release's SHA256SUM-w64-<version>, and copies rigctld.exe, exactly the
  DLLs it loads, and Hamlib's licence files. Then runs the copied
  rigctld.exe from that folder alone and checks --version and that -l lists
  the FTX-1 (model 1051).

  The DLL list was found with MSYS `ldd` (Git Bash) on 4.7.2's rigctld.exe
  and libhamlib-4.dll: libhamlib-4.dll, libusb-1.0.dll, libwinpthread-1.dll
  (libgcc_s_seh-1.dll is in the zip but not loaded). Re-check it for a new
  Hamlib version: the self-test below fails if one is missing.

  The zip has no licence text for libwinpthread-1.dll (the MinGW-w64
  runtime, MIT-style), so -WinpthreadsCopying takes winpthreads' COPYING
  from the mingw-w64 release the zip was built with (4.7.2's: v12.0.0,
  Debian 13's — the DLL says "2010-2023", GCC 13), shipped as
  COPYING-winpthreads.txt. libusb-1.0.dll (1.0.24) is LGPL-2.1-or-later,
  the text already in COPYING.LIB; its source tarball goes on the GitHub
  release, not in git (Apps/Windows/README.md, "Bundled rigctld").

.EXAMPLE
  .\fetch-rigctld.ps1 -Zip ~\Downloads\hamlib-w64-4.7.2.zip -WinpthreadsCopying ~\Downloads\winpthreads-COPYING
  # COPYING from https://raw.githubusercontent.com/mingw-w64/mingw-w64/v12.0.0/mingw-w64-libraries/winpthreads/COPYING
#>
param(
    [Parameter(Mandatory = $true)][string]$Zip,
    [Parameter(Mandatory = $true)][string]$WinpthreadsCopying,
    [string]$Version = '4.7.2',
    [string]$Sha256 = '8553bc6c5c6032e8debf99c017e98f58fed7e07e7c25d04815dc3e8bbe3304c7'
)

$ErrorActionPreference = 'Stop'

$dlls = @('libhamlib-4.dll', 'libusb-1.0.dll', 'libwinpthread-1.dll')
# Renamed from the zip's *.txt to the names the Mac's Vendor/hamlib uses;
# the README's ".w64-bin" would read as a resource qualifier to the PRI
# generator (warning PRI249).
$licences = @{
    'COPYING.txt'         = 'COPYING'
    'COPYING.LIB.txt'     = 'COPYING.LIB'
    'LICENSE.txt'         = 'LICENSE'
    'README.w64-bin.txt'  = 'README-w64-bin.txt'
}

if (-not (Select-String -LiteralPath $WinpthreadsCopying -Pattern 'mingw-w64 project' -Quiet)) {
    throw "$WinpthreadsCopying doesn't look like winpthreads' COPYING"
}

$actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Zip).Hash.ToLowerInvariant()
if ($actual -ne $Sha256.ToLowerInvariant()) {
    throw "SHA-256 mismatch for ${Zip}: got $actual, expected $Sha256"
}

$dest = Join-Path $PSScriptRoot '..\FTX1RemoteWindows\Vendor\hamlib' | Resolve-Path -ErrorAction SilentlyContinue
if (-not $dest) {
    $dest = Join-Path $PSScriptRoot '..\FTX1RemoteWindows\Vendor\hamlib'
    New-Item -ItemType Directory -Force $dest | Out-Null
    $dest = Resolve-Path $dest
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("hamlib-" + [guid]::NewGuid())
New-Item -ItemType Directory $work | Out-Null
try {
    Expand-Archive -LiteralPath $Zip -DestinationPath $work
    $root = Join-Path $work "hamlib-w64-$Version"
    if (-not (Test-Path (Join-Path $root 'bin\rigctld.exe'))) {
        throw "No hamlib-w64-$Version\bin\rigctld.exe in $Zip"
    }

    Get-ChildItem -LiteralPath $dest -File | Remove-Item -Confirm:$false
    foreach ($file in @('rigctld.exe') + $dlls) {
        Copy-Item -LiteralPath (Join-Path $root "bin\$file") -Destination $dest
    }
    foreach ($entry in $licences.GetEnumerator()) {
        Copy-Item -LiteralPath (Join-Path $root $entry.Key) -Destination (Join-Path $dest $entry.Value)
    }
    Copy-Item -LiteralPath $WinpthreadsCopying -Destination (Join-Path $dest 'COPYING-winpthreads.txt')
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $work -Confirm:$false
}

# Self-test from the vendored folder alone. Windows searches the exe's own
# folder for DLLs first; PATH is cleared so an installed Hamlib can't
# satisfy a missing one.
$rigctld = Join-Path $dest 'rigctld.exe'
$savedPath = $env:PATH
try {
    $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
    $versionOutput = @(& $rigctld --version 2>&1)
    $versionLine = [string]$versionOutput[0]
    if ($LASTEXITCODE -ne 0 -or $versionLine -notmatch "Hamlib $([regex]::Escape($Version))\b") {
        throw "rigctld.exe --version from $dest printed '$versionLine' (exit $LASTEXITCODE)"
    }
    $list = & $rigctld -l 2>&1
    if ($LASTEXITCODE -ne 0 -or -not ($list | Where-Object { $_ -match '^\s*1051\s' })) {
        throw "rigctld.exe -l from $dest doesn't list model 1051"
    }
}
finally {
    $env:PATH = $savedPath
}

$size = (Get-ChildItem -LiteralPath $dest -File | Measure-Object Length -Sum).Sum
Write-Host "Vendored $versionLine into $dest"
Write-Host ("{0:N1} MB total:" -f ($size / 1MB))
Get-ChildItem -LiteralPath $dest -File | ForEach-Object { Write-Host ("  {0,-22} {1,12:N0}" -f $_.Name, $_.Length) }
