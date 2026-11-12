; Inno Setup script for the FTX1Remote Windows app.
; Build with Apps\Windows\Tools\build-installer.ps1 (it publishes, reads the
; version from the .csproj and runs ISCC with the /D defines below).
;
;   /DAppVersion=0.12            required
;   /DSourceDir=C:\...\publish   required: the `dotnet publish` folder
;   /DOutputDir=C:\...\out       optional
;   /DSignTool                   optional: sign the setup and uninstaller (see [Setup])

#ifndef AppVersion
  #error Pass /DAppVersion=x.y (build-installer.ps1 does).
#endif
#ifndef SourceDir
  #error Pass /DSourceDir=<dotnet publish folder>.
#endif
#ifndef OutputDir
  #define OutputDir "..\..\..\build\installer"
#endif

#define AppName "FTX1 Remote"
#define AppExe "FTX1RemoteWindows.exe"

[Setup]
; Never change this GUID: upgrades find the old install through it.
AppId={{B7D3E1A4-5C2F-4E86-9A1B-3F0D8C6E7A52}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=captobie
AppPublisherURL=https://github.com/captobie/ftx1-remote
AppSupportURL=https://github.com/captobie/ftx1-remote/issues
AppUpdatesURL=https://github.com/captobie/ftx1-remote/releases
VersionInfoVersion={#AppVersion}
VersionInfoProductName={#AppName}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExe}
SetupIconFile=..\FTX1RemoteWindows\Assets\AppIcon.ico
OutputDir={#OutputDir}
OutputBaseFilename=FTX1Remote-Windows-{#AppVersion}-x64-setup
Compression=lzma2/ultra
SolidCompression=yes
WizardStyle=modern
; x64 only (the app is published for win-x64).
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Per-user by default; the wizard offers "all users" (UAC) on its first page,
; and /ALLUSERS or /CURRENTUSER choose on the command line.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
; We close the app and rigctld ourselves in [Code] (Restart Manager can't
; close a WinUI window cleanly and would also list rigctld's locked DLLs).
CloseApplications=no
RestartApplications=no
MinVersion=10.0.17763
; Windows 10 1809+ (the app's TargetPlatformMinVersion).
; Signing: add the tool in the build script's -SignTool parameter, which passes
;   /Ssigntool="<your signtool command with $f>" to ISCC. Then uncomment:
;SignTool=signtool
;SignedUninstaller=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "german"; MessagesFile: "compiler:Languages\German.isl"
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Everything dotnet publish produced, including hamlib\ (rigctld.exe, its DLLs
; and the Hamlib/libusb/winpthreads licence files), the es/de resource folders,
; Assets\ and the .pri/.xbf files.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; On an upgrade, remove the old app folder's contents first so nothing stale
; is left behind. Only if this really is our folder (the exe is there):
; a fresh install into some other non-empty folder must not wipe it.
; User data (settings, recordings, caches) lives in %LOCALAPPDATA%\FTX1RemoteWindows, not here.
Type: filesandordirs; Name: "{app}\*"; Check: IsExistingInstall

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
; Silent upgrade (e.g. an updater) of a copy that was running: start it again.
Filename: "{app}\{#AppExe}"; Flags: nowait runasoriginaluser skipifnotsilent; Check: WasRunning

[UninstallDelete]
Type: dirifempty; Name: "{app}"

[Code]
var
  AppWasRunning: Boolean;

function WasRunning: Boolean;
begin
  Result := AppWasRunning;
end;

function IsExistingInstall: Boolean;
begin
  Result := FileExists(ExpandConstant('{app}\{#AppExe}'));
end;

{ ---- Closing the app and rigctld ------------------------------------------ }

{ PowerShell helper, written to a temp file. Exit code 0 = nothing of ours
  left running, 1 = the app is still running. Whether the app was running at
  all is reported through a marker file.
  1. Ask the app to close (CloseMainWindow: it saves settings and stops the
     rigctld it spawned itself), wait up to $Grace seconds.
  2. With -Force, kill it if it didn't.
  3. Kill any rigctld.exe (or other process) still running from the install
     folder, matched by full path so another program's rigctld (WSJT-X) is left alone. }
function StopScript: String;
begin
  Result :=
    'param([string]$Dir,[int]$Grace=15,[switch]$Force,[string]$Marker)' + #13#10 +
    '$ErrorActionPreference = ''SilentlyContinue''' + #13#10 +
    '$prefix = $Dir.TrimEnd(''\'') + ''\''' + #13#10 +
    'function Mine { Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } }' + #13#10 +
    '$apps = @(Mine | Where-Object { $_.Name -eq ''{#AppExe}'' })' + #13#10 +
    'if ($apps.Count -gt 0 -and $Marker) { Set-Content -Path $Marker -Value ''1'' }' + #13#10 +
    'foreach ($a in $apps) { (Get-Process -Id $a.ProcessId).CloseMainWindow() | Out-Null }' + #13#10 +
    '$deadline = (Get-Date).AddSeconds($Grace)' + #13#10 +
    'while ((Get-Date) -lt $deadline -and @(Mine | Where-Object { $_.Name -eq ''{#AppExe}'' }).Count -gt 0) { Start-Sleep -Milliseconds 300 }' + #13#10 +
    'if (@(Mine | Where-Object { $_.Name -eq ''{#AppExe}'' }).Count -gt 0) {' + #13#10 +
    '  if (-not $Force) { exit 1 }' + #13#10 +
    '  Mine | Where-Object { $_.Name -eq ''{#AppExe}'' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }' + #13#10 +
    '}' + #13#10 +
    'Start-Sleep -Seconds 2' + #13#10 +
    'Mine | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }' + #13#10 +
    'Start-Sleep -Milliseconds 500' + #13#10 +
    'exit 0' + #13#10;
end;

{ Returns the script's exit code, or -1 if PowerShell couldn't be run. }
function RunStop(const Dir: String; Grace: Integer; Force: Boolean; const Marker: String): Integer;
var
  Script, Args: String;
  Code: Integer;
begin
  Script := ExpandConstant('{tmp}\ftx1-stop.ps1');
  SaveStringToFile(Script, StopScript, False);
  Args := '-NoProfile -ExecutionPolicy Bypass -File "' + Script + '" -Dir "' + Dir + '" -Grace ' + IntToStr(Grace) +
    ' -Marker "' + Marker + '"';
  if Force then
    Args := Args + ' -Force';
  if Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Args, '', SW_HIDE, ewWaitUntilTerminated, Code) then
    Result := Code
  else
    Result := -1;
end;

function CloseRunningApp(const Dir: String; var NeededClose: Boolean): String;
var
  Marker: String;
  Code: Integer;
begin
  Result := '';
  Marker := ExpandConstant('{tmp}\ftx1-was-running.txt');
  DeleteFile(Marker);
  Code := RunStop(Dir, 15, False, Marker);
  while Code = 1 do
  begin
    if WizardSilent or UninstallSilent then
    begin
      { Unattended (an updater drives us): there is nobody to ask. }
      Code := RunStop(Dir, 5, True, Marker);
      Break;
    end;
    if MsgBox('{#AppName} is still running and has not closed itself.' + #13#10#13#10 +
        'Disconnect and close it, then click Retry. Cancel stops this without changing anything.',
        mbConfirmation, MB_RETRYCANCEL) = IDCANCEL then
    begin
      Result := '{#AppName} is still running. Close it and run this again.';
      Exit;
    end;
    Code := RunStop(Dir, 15, False, Marker);
  end;
  NeededClose := FileExists(Marker);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := CloseRunningApp(ExpandConstant('{app}'), AppWasRunning);
end;

function InitializeUninstall: Boolean;
var
  Dummy: Boolean;
  Err: String;
begin
  Err := CloseRunningApp(ExpandConstant('{app}'), Dummy);
  Result := Err = '';
  if not Result then
    SuppressibleMsgBox(Err, mbError, MB_OK, IDOK);
end;

{ ---- WebView2 runtime ------------------------------------------------------ }

function WebView2Installed: Boolean;
var
  V: String;
begin
  { Evergreen runtime, per its documented detection keys. The 64-bit hive view
    needs the explicit WOW6432Node path, the per-user key has none. }
  Result := False;
  if RegQueryStringValue(HKLM, 'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', V) then
    Result := (V <> '') and (V <> '0.0.0.0');
  if not Result then
    if RegQueryStringValue(HKCU, 'Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', V) then
      Result := (V <> '') and (V <> '0.0.0.0');
end;

procedure InstallWebView2;
var
  Setup: String;
  Code: Integer;
begin
  Setup := ExpandConstant('{tmp}\MicrosoftEdgeWebview2Setup.exe');
  try
    DownloadTemporaryFile('https://go.microsoft.com/fwlink/p/?LinkId=2124703', 'MicrosoftEdgeWebview2Setup.exe', '', nil);
    Exec(Setup, '/silent /install', '', SW_SHOW, ewWaitUntilTerminated, Code);
  except
    SuppressibleMsgBox('The WebView2 runtime could not be downloaded. The WebSDR, MyKiwiSDR and APRS map windows need it.' + #13#10 +
      'Install it from https://developer.microsoft.com/microsoft-edge/webview2/ and start {#AppName} again.',
      mbInformation, MB_OK, IDOK);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and not WebView2Installed then
  begin
    if WizardSilent or
       (SuppressibleMsgBox('{#AppName} uses the Microsoft Edge WebView2 runtime for its WebSDR, MyKiwiSDR and APRS map windows, and it is not installed on this PC.' + #13#10#13#10 +
         'Download and install it now?', mbConfirmation, MB_YESNO, IDYES) = IDYES) then
      InstallWebView2;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    SuppressibleMsgBox('Your settings, recordings and caches were kept in' + #13#10 +
      ExpandConstant('{localappdata}\FTX1RemoteWindows') + #13#10 +
      'Delete that folder if you want them gone too.', mbInformation, MB_OK, IDOK);
end;
