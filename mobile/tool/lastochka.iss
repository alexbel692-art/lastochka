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
UninstallDisplayName=Ласточка
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; ярлыки предварительной версии
Type: files; Name: "{commonprograms}\Ласточка (новая версия).lnk"
Type: files; Name: "{commondesktop}\Ласточка (новая версия).lnk"

[Icons]
Name: "{commonprograms}\Ласточка"; Filename: "{app}\Lastochka.exe"; AppUserModelID: "Lastochka.App"
Name: "{commondesktop}\Ласточка"; Filename: "{app}\Lastochka.exe"; Tasks: desktopicon; AppUserModelID: "Lastochka.App"

[Run]
; обычная установка — галочка «Запустить»; тихое автообновление — запускаем сами
Filename: "{app}\Lastochka.exe"; Description: "{cm:LaunchProgram,Ласточка}"; Flags: nowait postinstall skipifsilent runasoriginaluser
Filename: "{app}\Lastochka.exe"; Flags: nowait runasoriginaluser skipifnotsilent

[Code]
// Защита от отката: более старую версию поверх новой не ставим (её могли подсунуть, чтобы вернуть
// исправленную уязвимость). Осознанно откатиться можно с ключом /ALLOWDOWNGRADE.
function InitializeSetup(): Boolean;
var
  Installed: String;
  Cur, Old: Int64;
begin
  Result := True;
  if Pos('/ALLOWDOWNGRADE', UpperCase(GetCmdTail)) > 0 then Exit;
  if not RegQueryStringValue(HKLM64, 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{5E0C2B7A-3D4F-4B8E-9C1A-7F2D6E8B4A10}_is1', 'DisplayVersion', Installed) then Exit;
  if not StrToVersion('{#AppVer}', Cur) then Exit;
  if not StrToVersion(Installed, Old) then Exit;
  if ComparePackedVersion(Cur, Old) < 0 then
  begin
    if not WizardSilent then
      MsgBox('Уже установлена более новая Ласточка (' + Installed + '). Установка старой версии ({#AppVer}) отменена.', mbError, MB_OK);
    Result := False;
  end;
end;

// Прежняя версия Ласточки (3.x) установлена отдельной программой — после установки новой удаляем её тихо.
procedure RemoveOldFrom(RootKey: Integer);
var
  Names: TArrayOfString;
  I, RC, P: Integer;
  Key, Name, Quiet, Exe, Params: String;
begin
  Key := 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';
  if not RegGetSubkeyNames(RootKey, Key, Names) then Exit;
  for I := 0 to GetArrayLength(Names) - 1 do
  begin
    if Pos('5E0C2B7A', Names[I]) > 0 then Continue;
    if not RegQueryStringValue(RootKey, Key + '\' + Names[I], 'DisplayName', Name) then Continue;
    if Pos('Ласточка 3.', Name) <> 1 then Continue;
    if not RegQueryStringValue(RootKey, Key + '\' + Names[I], 'QuietUninstallString', Quiet) then Continue;
    // команду удаления разбираем сами (без cmd /C) и запускаем только существующий .exe
    Exe := Trim(Quiet); Params := '';
    if Copy(Exe, 1, 1) = '"' then
    begin
      Delete(Exe, 1, 1);
      P := Pos('"', Exe);
      if P = 0 then Continue;
      Params := Trim(Copy(Exe, P + 1, MaxInt));
      Exe := Copy(Exe, 1, P - 1);
    end else Continue;
    if CompareText(ExtractFileExt(Exe), '.exe') <> 0 then Continue;
    if not FileExists(Exe) then Continue;
    Log('Удаляем прежнюю версию: ' + Name);
    if RootKey = HKCU then
      // запись пользователя может подложить любая программа — запускаем без прав администратора
      ExecAsOriginalUser(Exe, Params, '', SW_HIDE, ewWaitUntilTerminated, RC)
    else
      Exec(Exe, Params, '', SW_HIDE, ewWaitUntilTerminated, RC);
  end;
end;

// На сервере удалённых рабочих столов Ласточка может быть открыта у других пользователей: её файлы заняты,
// и установщик не может их заменить (обновление молча не вставало). Перед заменой файлов закрываем все копии
// Ласточки на этом компьютере — у всех пользователей. Права администратора у установщика уже есть.
procedure CloseAllCopies();
var
  RC: Integer;
begin
  Log('Закрываем все копии Ласточки на компьютере');
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM Lastochka.exe', '', SW_HIDE, ewWaitUntilTerminated, RC);
  Log('taskkill: код ' + IntToStr(RC));
  Sleep(1500);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then CloseAllCopies();
  if CurStep = ssPostInstall then
  begin
    RemoveOldFrom(HKLM64);
    RemoveOldFrom(HKLM32);
    RemoveOldFrom(HKCU);
  end;
end;
