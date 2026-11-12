<#
.SYNOPSIS
  Publishes the Windows app and builds the Inno Setup installer.

.DESCRIPTION
  1. Reads <Version> from FTX1RemoteWindows.csproj.
  2. (unless -SkipPublish) publishes into an EMPTY folder (self-contained win-x64).
  3. Runs ISCC on FTX1Remote.iss with /DAppVersion /DSourceDir /DOutputDir.
  Output: <repo>\build\installer\FTX1Remote-Windows-<version>-x64-setup.exe (gitignored).

.PARAMETER SignTool
  Optional. Full signtool command line with $f for the file, e.g.
  'signtool.exe sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /a $f'
  (or an Artifact Signing / trusted-signing dlib command). Passed to ISCC as
  /Ssigntool=...; also uncomment SignTool=signtool in FTX1Remote.iss.
#>
param(
  [string]$PublishDir = 'C:\Tools\FTX1Remote-release',
  [string]$OutputDir,
  [switch]$SkipPublish,
  [string]$Iscc,
  [string]$SignTool
)
$ErrorActionPreference = 'Stop'

$tools = $PSScriptRoot
$proj = Join-Path $tools '..\FTX1RemoteWindows\FTX1RemoteWindows.csproj' | Resolve-Path
$repo = Resolve-Path (Join-Path $tools '..\..\..')
if (-not $OutputDir) { $OutputDir = Join-Path $repo 'build\installer' }

$version = ([xml](Get-Content $proj)).Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1
if (-not $version) { throw "No <Version> in $proj" }
Write-Host "Version $version"

if (-not $Iscc) {
  $candidates = @(
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe")
  $Iscc = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $Iscc) { $Iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source }
}
if (-not $Iscc -or -not (Test-Path $Iscc)) { throw 'ISCC.exe not found. Install Inno Setup 6 (winget install JRSoftware.InnoSetup) or pass -Iscc.' }

if (-not $SkipPublish) {
  if (Test-Path $PublishDir) { Remove-Item -Recurse -Force $PublishDir }
  & 'C:\Program Files\dotnet\dotnet.exe' publish $proj -c Release -r win-x64 --self-contained -o $PublishDir
  if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed' }
}
if (-not (Test-Path (Join-Path $PublishDir 'FTX1RemoteWindows.exe'))) { throw "No FTX1RemoteWindows.exe in $PublishDir" }
$rigctld = Join-Path $PublishDir 'hamlib\rigctld.exe'
if (-not (Test-Path $rigctld)) { throw "Bundled rigctld missing: $rigctld" }
Write-Host ("Bundled " + (& $rigctld --version 2>&1 | Select-Object -First 1))

New-Item -ItemType Directory -Force $OutputDir | Out-Null
$isccArgs = @("/DAppVersion=$version", "/DSourceDir=$PublishDir", "/DOutputDir=$OutputDir")
if ($SignTool) { $isccArgs += "/Ssigntool=$SignTool" }
& $Iscc @isccArgs (Join-Path $tools 'FTX1Remote.iss')
if ($LASTEXITCODE -ne 0) { throw 'ISCC failed' }

$setup = Join-Path $OutputDir "FTX1Remote-Windows-$version-x64-setup.exe"
Write-Host ("Built {0} ({1:N1} MB)" -f $setup, ((Get-Item $setup).Length / 1MB))
