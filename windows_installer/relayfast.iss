#define AppName "RelayFastVPN"
#define AppVersion GetEnv("RF_VERSION")

[Setup]
AppId={{B7C5E0F4-5A57-4E0B-9E8B-2D6A9F1A7C11}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=RelayFastVPN
DefaultDirName={autopf}\RelayFastVPN
DefaultGroupName=RelayFastVPN
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=RelayFastVPN-Setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\RelayFastVPN.exe
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
WizardStyle=modern
CloseApplications=yes
RestartApplications=yes

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "Ярлык на рабочем столе"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion
Source: "..\core\*"; DestDir: "{app}\core"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\RelayFastVPN"; Filename: "{app}\RelayFastVPN.exe"
Name: "{autodesktop}\RelayFastVPN"; Filename: "{app}\RelayFastVPN.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\RelayFastVPN.exe"; Description: "Запустить RelayFastVPN"; Flags: nowait postinstall
