; Inno Setup script for Forge — Build Better Every Day.
;
; Packages the entire Flutter Windows release folder
;   build\windows\x64\runner\Release\
; into a single per-user installer (no administrator rights required):
;   Forge-<version>-windows-setup.exe
;
; It creates Start-menu and (optional) desktop shortcuts and bundles the
; Microsoft Visual C++ 2015-2022 x64 redistributable, running it silently on
; first install so the app's runtime dependency is always satisfied.
;
; Build (locally or in CI, after `flutter build windows --release`):
;   iscc /DAppVersion=0.1.0 packaging\windows\forge.iss
; The CI step downloads vc_redist.x64.exe next to this script before compiling.

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif

#define AppName "Forge"
#define AppPublisher "Forge contributors"
#define AppId "app.forge.forge"
#define AppExeName "forge.exe"
; Path to the built release folder, relative to this .iss file.
#define BuildDir "..\..\build\windows\x64\runner\Release"
; VC++ redistributable, downloaded next to this script by the CI step.
#define VcRedist "vc_redist.x64.exe"

[Setup]
AppId={{8F5B2E14-3C7A-4D9E-9A1F-app.forge.forge}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
VersionInfoVersion={#AppVersion}
; Per-user install — no admin elevation required.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#AppExeName}
OutputBaseFilename=Forge-{#AppVersion}-windows-setup
OutputDir=.
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The entire Flutter release output (executable, flutter_windows.dll, data\, plugins).
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
; Bundle the VC++ redistributable when present so [Run] can execute it.
; skipifsourcedoesntexist lets the script compile even when the redist has not
; been downloaded yet (a bare local compile); CI downloads it before iscc runs.
Source: "{#VcRedist}"; DestDir: "{tmp}"; Flags: deleteafterinstall skipifsourcedoesntexist

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
; Silently install the VC++ runtime, then optionally launch the app.
Filename: "{tmp}\{#VcRedist}"; Parameters: "/install /quiet /norestart"; \
  StatusMsg: "Installing Microsoft Visual C++ runtime..."; Check: VcRedistBundled; Flags: waituntilterminated
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; \
  Flags: nowait postinstall skipifsilent

[Code]
// Only reference the bundled VC++ redistributable when it was shipped with the
// installer. This keeps the script compilable even if the file is absent
// (the CI step downloads it; a bare local compile still succeeds).
function VcRedistBundled: Boolean;
begin
  Result := FileExists(ExpandConstant('{src}\{#VcRedist}'));
end;
