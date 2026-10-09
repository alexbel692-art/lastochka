#define AppVer GetEnv("APP_VERSION")

[Setup]
AppId={{5E0C2B7A-3D4F-4B8E-9C1A-7F2D6E8B4A10}
AppName=Ласточка
AppVersion={#AppVer}
AppVerName=Ласточка {#AppVer}
DefaultDirName={autopf}\Lastochka
DisableProgramGroupPage=yes
DisableDirPage=yes
; для всех пользователей компьютера — подходит для RDP-сервера
PrivilegesRequired=admin
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
OutputDir=..\..\dist
OutputBaseFilename=Lastochka-Setup-{#AppVer}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\Lastochka.exe
UninstallDisplayName=Ласточка (новая версия)
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{commonprograms}\Ласточка (новая версия)"; Filename: "{app}\Lastochka.exe"
Name: "{commondesktop}\Ласточка (новая версия)"; Filename: "{app}\Lastochka.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Lastochka.exe"; Description: "{cm:LaunchProgram,Ласточка}"; Flags: nowait postinstall skipifsilent
