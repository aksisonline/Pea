; Pea installer (Inno Setup 6.6+). Built by scripts/package-windows.ps1 -Installer.
;   ISCC /DAppVersion=1.0.0 /DStageDir=dist\Pea-1.0.0-windows-x64 /DOutDir=dist packaging\windows\pea.iss
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef StageDir
  #define StageDir "..\..\dist\stage"
#endif
#ifndef OutDir
  #define OutDir "..\..\dist"
#endif

#define AppName "Pea"
#define AppExe "PeaWindows.exe"

[Setup]
AppId={{6C1D5E52-7B7A-4B8F-9A4A-5EA0D0A11E01}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=aksisonline
AppPublisherURL=https://github.com/aksisonline/Pea
AppSupportURL=https://github.com/aksisonline/Pea/issues
AppUpdatesURL=https://github.com/aksisonline/Pea/releases
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
DisableDirPage=auto
; Per-user by default (no UAC prompt); the user can still pick "all users" in the dialog.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir={#OutDir}
OutputBaseFilename=Pea-windows-x64-setup
SetupIconFile=..\..\assets\Pea.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
LicenseFile=..\..\LICENSE
Compression=lzma2/ultra64
SolidCompression=yes
; Modern look: Windows 11 style wizard that follows the system light/dark setting.
WizardStyle=modern dynamic
WizardImageFile=wizard.bmp,wizard@2x.bmp
WizardSmallImageFile=wizard-small.bmp,wizard-small@2x.bmp
WizardImageAlphaFormat=none
WizardSizePercent=110
ShowLanguageDialog=no
CloseApplications=force
RestartApplications=no
UsePreviousTasks=yes
SetupMutex=PeaSetupMutex

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "startup"; Description: "Start Pea when I sign in to Windows"; GroupDescription: "Startup:"

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"; IconFilename: "{app}\Pea.ico"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; IconFilename: "{app}\Pea.ico"; Tasks: desktopicon

[Registry]
Root: HKA; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "{#AppName}"; \
  ValueData: """{app}\{#AppExe}"""; Flags: uninsdeletevalue; Tasks: startup

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
