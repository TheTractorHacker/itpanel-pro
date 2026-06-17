; ITPanel Pro - Inno Setup installer
;
; Installs the tray app and prompts for per-install configuration
; (ITFlow base URL, API key, client ID, contact ID, priority), writing
; the result to %ProgramData%\ITPanelPro\config.json.
;
; If an older "ITFlow Quick Ticket" install is detected (old AppId), it is
; silently uninstalled first and its config.json is migrated so existing
; deployments upgrade cleanly to ITPanel Pro.
;
; Build:  ISCC.exe ITPanelPro.iss
; Output: installer\Output\ITPanelProSetup.exe
;
; Supports unattended installs, e.g.:
;   ITPanelProSetup.exe /VERYSILENT /SUPPRESSMSGBOXES ^
;     /ItflowBaseUrl=https://itflow.foleyit.com ^
;     /ApiKey=XXXXXXXX /ClientId=5 /ContactId=12 /Priority=Medium

#define MyAppName "ITPanel Pro"
#define MyAppVersion "2.1.1"
#define MyAppPublisher "Foley IT"
#define MyAppExeName "ITPanelPro.exe"
#define OldAppId "{B7B6A6E1-6E0C-4C2D-9F2F-7C1D4A9E3B21}"

[Setup]
AppId={{9EAF8FE4-782D-48E8-BFC8-51D9F008F82E}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\ITPanelPro
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=Output
OutputBaseFilename=ITPanelProSetup
Compression=lzma
SolidCompression=yes
SetupIconFile=..\Windows\assets\icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64
; Give the wizard a bit more room so the connection-settings page (5 fields
; plus description) doesn't get cut off.
WizardSizePercent=110,130
; Re-running this installer (e.g. for an upgrade) closes the running tray
; app so its exe can be overwritten, and restarts it afterwards.
CloseApplications=force
RestartApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "..\Windows\dist\ITPanelPro.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
; Start on login for all users
Name: "{commonstartup}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
; Start menu shortcut (optional, useful for manually launching/testing)
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName} now"; Flags: nowait postinstall skipifsilent
; Silent/very silent runs (unattended deploys and the tray app's
; self-update) skip the entry above, and RestartApplications=yes can't
; relaunch the app since it never registered with Restart Manager - so
; relaunch it explicitly here when running silently.
Filename: "{app}\{#MyAppExeName}"; Flags: nowait; Check: WizardSilent

[Code]
var
  ConfigPage: TInputQueryWizardPage;

// Extracts the value of a top-level "key": value pair from the simple,
// known-format JSON written by WriteConfigFile below. Returns '' if the
// key isn't found. Strings are returned unquoted; "null" is returned as-is.
function ExtractJsonValue(const Json, Key: String): String;
var
  SearchStr: String;
  StartPos, EndPos: Integer;
begin
  Result := '';
  SearchStr := '"' + Key + '"';
  StartPos := Pos(SearchStr, Json);
  if StartPos = 0 then exit;
  StartPos := StartPos + Length(SearchStr);

  while (StartPos <= Length(Json)) and (Json[StartPos] <> ':') do
    StartPos := StartPos + 1;
  StartPos := StartPos + 1; // skip ':'

  while (StartPos <= Length(Json)) and ((Json[StartPos] = ' ') or (Json[StartPos] = #9)) do
    StartPos := StartPos + 1;

  if (StartPos <= Length(Json)) and (Json[StartPos] = '"') then
  begin
    StartPos := StartPos + 1;
    EndPos := StartPos;
    while (EndPos <= Length(Json)) and (Json[EndPos] <> '"') do
      EndPos := EndPos + 1;
    Result := Copy(Json, StartPos, EndPos - StartPos);
  end
  else
  begin
    EndPos := StartPos;
    while (EndPos <= Length(Json)) and (Json[EndPos] <> ',') and (Json[EndPos] <> '}')
          and (Json[EndPos] <> #13) and (Json[EndPos] <> #10) do
      EndPos := EndPos + 1;
    Result := Trim(Copy(Json, StartPos, EndPos - StartPos));
  end;
end;

// Resolves a config field's initial value: an explicit /param: always wins,
// otherwise fall back to the existing config.json (for upgrades), otherwise
// the given default.
function ConfigDefault(const ParamName, JsonKey, ExistingJson, FallbackDefault: String): String;
var
  ParamValue, JsonValue: String;
begin
  ParamValue := ExpandConstant('{param:' + ParamName + '|__UNSET__}');
  if ParamValue <> '__UNSET__' then
  begin
    Result := ParamValue;
    exit;
  end;

  if ExistingJson <> '' then
  begin
    JsonValue := ExtractJsonValue(ExistingJson, JsonKey);
    if (JsonKey = 'contact_id') and (JsonValue = 'null') then
      JsonValue := '';
    if JsonValue <> '' then
    begin
      Result := JsonValue;
      exit;
    end;
  end;

  Result := FallbackDefault;
end;

// Silently uninstalls a previous "ITFlow Quick Ticket" install (old AppId)
// if one is found, so upgrades to ITPanel Pro don't leave a stale install
// or duplicate startup entry behind.
procedure UninstallOldVersion;
var
  UninstallString: String;
  ResultCode: Integer;
begin
  if RegQueryStringValue(HKLM, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{#OldAppId}_is1',
       'QuietUninstallString', UninstallString)
     or RegQueryStringValue(HKLM, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{#OldAppId}_is1',
       'UninstallString', UninstallString) then
  begin
    UninstallString := RemoveQuotes(UninstallString);
    Exec(UninstallString, '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART', '', SW_HIDE,
      ewWaitUntilTerminated, ResultCode);
  end;
end;

function InitializeSetup(): Boolean;
begin
  UninstallOldVersion;
  Result := True;
end;

procedure InitializeWizard;
var
  ConfigPath, OldConfigPath, ExistingJson: String;
  ExistingJsonA: AnsiString;
begin
  ConfigPath := ExpandConstant('{commonappdata}\ITPanelPro\config.json');
  OldConfigPath := ExpandConstant('{commonappdata}\ITFlowQuickTicket\config.json');
  ExistingJson := '';
  if FileExists(ConfigPath) then
  begin
    LoadStringFromFile(ConfigPath, ExistingJsonA);
    ExistingJson := String(ExistingJsonA);
  end
  else if FileExists(OldConfigPath) then
  begin
    // Migrate settings from a previous "ITFlow Quick Ticket" install.
    LoadStringFromFile(OldConfigPath, ExistingJsonA);
    ExistingJson := String(ExistingJsonA);
  end;

  ConfigPage := CreateInputQueryPage(wpSelectDir,
    'ITFlow Connection Settings',
    'Configure this install to talk to your ITFlow instance',
    'API key: Admin > API Keys. Client ID: on the client''s page in ITFlow. ' +
    'Existing settings are pre-filled and kept on upgrades unless changed.');

  ConfigPage.Add('ITFlow Base URL (e.g. https://itflow.example.com):', False);
  ConfigPage.Add('API Key:', False);
  ConfigPage.Add('Client ID:', False);
  ConfigPage.Add('Contact ID (optional):', False);
  ConfigPage.Add('Priority (Low / Medium / High / Critical):', False);

  ConfigPage.Values[0] := ConfigDefault('ItflowBaseUrl', 'itflow_base_url', ExistingJson, 'https://');
  ConfigPage.Values[1] := ConfigDefault('ApiKey', 'api_key', ExistingJson, '');
  ConfigPage.Values[2] := ConfigDefault('ClientId', 'client_id', ExistingJson, '');
  ConfigPage.Values[3] := ConfigDefault('ContactId', 'contact_id', ExistingJson, '');
  ConfigPage.Values[4] := ConfigDefault('Priority', 'priority', ExistingJson, 'Medium');
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;

  if CurPageID = ConfigPage.ID then
  begin
    if (Trim(ConfigPage.Values[0]) = '') or (Trim(ConfigPage.Values[0]) = 'https://') then
    begin
      MsgBox('Please enter the ITFlow base URL.', mbError, MB_OK);
      Result := False;
      exit;
    end;

    if Trim(ConfigPage.Values[1]) = '' then
    begin
      MsgBox('Please enter the API key.', mbError, MB_OK);
      Result := False;
      exit;
    end;

    if (Trim(ConfigPage.Values[2]) = '') or
       (StrToIntDef(Trim(ConfigPage.Values[2]), -1) < 0) then
    begin
      MsgBox('Please enter a valid numeric Client ID.', mbError, MB_OK);
      Result := False;
      exit;
    end;
  end;
end;

// Escapes a string for safe embedding in a JSON double-quoted string.
function JsonEscape(const S: String): String;
var
  R: String;
  I: Integer;
  C: Char;
begin
  R := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    case C of
      '"':  R := R + '\"';
      '\':  R := R + '\\';
    else
      R := R + C;
    end;
  end;
  Result := R;
end;

procedure WriteConfigFile;
var
  BaseUrl, ApiKey, ClientId, ContactId, Priority: String;
  ContactJson: String;
  Json: String;
  ConfigDir, ConfigPath: String;
begin
  BaseUrl  := Trim(ConfigPage.Values[0]);
  ApiKey   := Trim(ConfigPage.Values[1]);
  ClientId := Trim(ConfigPage.Values[2]);
  ContactId := Trim(ConfigPage.Values[3]);
  Priority := Trim(ConfigPage.Values[4]);

  if Priority = '' then
    Priority := 'Medium';

  if ContactId = '' then
    ContactJson := 'null'
  else
    ContactJson := ContactId;

  Json := '{' + #13#10 +
    '    "itflow_base_url": "' + JsonEscape(BaseUrl) + '",' + #13#10 +
    '    "api_key": "' + JsonEscape(ApiKey) + '",' + #13#10 +
    '    "client_id": ' + ClientId + ',' + #13#10 +
    '    "contact_id": ' + ContactJson + ',' + #13#10 +
    '    "priority": "' + JsonEscape(Priority) + '"' + #13#10 +
    '}' + #13#10;

  ConfigDir := ExpandConstant('{commonappdata}\ITPanelPro');
  ConfigPath := ConfigDir + '\config.json';

  if not DirExists(ConfigDir) then
    ForceDirectories(ConfigDir);

  SaveStringToFile(ConfigPath, Json, False);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  SrcDir: String;
  ResultCode: Integer;
begin
  if CurStep = ssPostInstall then
    WriteConfigFile;

  if CurStep = ssDone then
  begin
    // If this installer was downloaded by the tray app's self-update (see
    // do_self_update in common/core.py), it lives in its own temp folder
    // named "itpanelpro_update_*". Clean that folder up now that the
    // install is done, after a short delay so this exe can be removed.
    SrcDir := ExtractFileDir(ExpandConstant('{srcexe}'));
    if Pos('itpanelpro_update_', Lowercase(ExtractFileName(SrcDir))) = 1 then
      Exec(ExpandConstant('{cmd}'), '/C ping -n 3 127.0.0.1 >nul & rmdir /s /q "' + SrcDir + '"',
        '', SW_HIDE, ewNoWait, ResultCode);
  end;
end;
