; Inno Setup script for the Windows build.
; Build first:  cd app && flutter build windows --release
; Then compile this with Inno Setup 6 (iscc packaging\windows-installer.iss).

#define AppName "Taa'a Yuku Radar"
#define AppExe "radar_app.exe"
#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif

[Setup]
AppId={{7C2B1E64-3F0B-4C1E-9D6E-4F3B2A9C51D7}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Taa'a Yuku Radar contributors
DefaultDirName={autopf}\Taa'a Yuku Radar
DefaultGroupName={#AppName}
OutputDir=..\dist
OutputBaseFilename=radar-app-{#AppVersion}-windows-setup
Compression=lzma2/max
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible
WizardStyle=modern
; The installer .exe itself gets the app icon; the installed program picks it
; up from the resources compiled into radar_app.exe.
SetupIconFile=..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts"; Flags: unchecked

[Files]
Source: "..\app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent
