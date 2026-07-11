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
#define MyAppVersion "2.1.9"
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
  PickerPage: TWizardPage;
  ClientSearchEdit, ContactSearchEdit: TNewEdit;
  ClientSearchBtn, ContactSearchBtn: TNewButton;
  ClientResultsBox, ContactResultsBox: TNewListBox;
  ClientResultIds, ContactResultIds: TStringList;
  PickerStatusLabel: TNewStaticText;

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

// Escapes a string for embedding inside a PowerShell single-quoted string
// literal (only a literal ' needs doubling; unlike double-quoted PS
// strings, $ and backslash aren't special so nothing else needs escaping).
function PsSingleQuoteEscape(const S: String): String;
begin
  Result := S;
  StringChangeEx(Result, '''', '''''', True);
end;

// Runs a small generated PowerShell script (writing it to {tmp} rather than
// passing it as a -Command string, so values with spaces/quotes/apostrophes
// - client names commonly have them - don't fight Windows command-line
// quoting) and reads back the "id<TAB>name" lines it wrote. Returns False
// if the request failed or matched nothing; Lines holds the raw output
// either way (an "ERROR<TAB>..." line on failure).
function RunItflowSearch(const Script: String; Lines: TStringList): Boolean;
var
  ScriptPath, OutPath: String;
  ResultCode: Integer;
begin
  Result := False;
  Lines.Clear;

  ScriptPath := ExpandConstant('{tmp}\itflow_search.ps1');
  OutPath := ExpandConstant('{tmp}\itflow_search_out.txt');
  DeleteFile(OutPath);
  SaveStringToFile(ScriptPath, Script, False);

  Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -ExecutionPolicy Bypass -File "' + ScriptPath + '"', '',
    SW_HIDE, ewWaitUntilTerminated, ResultCode);

  if not FileExists(OutPath) then
    exit;

  Lines.LoadFromFile(OutPath);
  // Out-File -Encoding utf8 on Windows PowerShell 5.1 prepends a BOM; strip
  // it defensively in case TStringList didn't already.
  if (Lines.Count > 0) and (Length(Lines[0]) > 0) and (Ord(Lines[0][1]) = 65279) then
    Lines[0] := Copy(Lines[0], 2, Length(Lines[0]) - 1);

  Result := (Lines.Count > 0) and (Copy(Lines[0], 1, 5) <> 'ERROR');
end;

function SearchItflowClients(const BaseUrl, ApiKey, SearchTerm: String; Lines: TStringList): Boolean;
var
  Script, OutPath: String;
begin
  OutPath := ExpandConstant('{tmp}\itflow_search_out.txt');
  Script :=
    '$ErrorActionPreference = ''Stop''' + #13#10 +
    '$search = ''' + PsSingleQuoteEscape(SearchTerm) + '''' + #13#10 +
    'try {' + #13#10 +
    '  $uri = ''' + PsSingleQuoteEscape(BaseUrl) + '/api/v1/clients?limit=15&search='' + [uri]::EscapeDataString($search)' + #13#10 +
    '  $resp = Invoke-RestMethod -Uri $uri -Headers @{ ''X-Api-Key'' = ''' + PsSingleQuoteEscape(ApiKey) + ''' } -UseBasicParsing' + #13#10 +
    '  $resp.data | ForEach-Object { "$($_.id)`t$($_.name -replace ''`t'', '' '')" } | Out-File -FilePath ''' + PsSingleQuoteEscape(OutPath) + ''' -Encoding utf8' + #13#10 +
    '} catch {' + #13#10 +
    '  "ERROR`t" + $_.Exception.Message | Out-File -FilePath ''' + PsSingleQuoteEscape(OutPath) + ''' -Encoding utf8' + #13#10 +
    '}' + #13#10;
  Result := RunItflowSearch(Script, Lines);
end;

function SearchItflowContacts(const BaseUrl, ApiKey: String; ClientId: Integer; const SearchTerm: String; Lines: TStringList): Boolean;
var
  Script, OutPath: String;
begin
  OutPath := ExpandConstant('{tmp}\itflow_search_out.txt');
  Script :=
    '$ErrorActionPreference = ''Stop''' + #13#10 +
    '$search = ''' + PsSingleQuoteEscape(SearchTerm) + '''' + #13#10 +
    'try {' + #13#10 +
    '  $uri = ''' + PsSingleQuoteEscape(BaseUrl) + '/api/v1/contacts?limit=15&client_id=' + IntToStr(ClientId) + '&search='' + [uri]::EscapeDataString($search)' + #13#10 +
    '  $resp = Invoke-RestMethod -Uri $uri -Headers @{ ''X-Api-Key'' = ''' + PsSingleQuoteEscape(ApiKey) + ''' } -UseBasicParsing' + #13#10 +
    '  $resp.data | ForEach-Object { "$($_.id)`t$($_.name -replace ''`t'', '' '')" } | Out-File -FilePath ''' + PsSingleQuoteEscape(OutPath) + ''' -Encoding utf8' + #13#10 +
    '} catch {' + #13#10 +
    '  "ERROR`t" + $_.Exception.Message | Out-File -FilePath ''' + PsSingleQuoteEscape(OutPath) + ''' -Encoding utf8' + #13#10 +
    '}' + #13#10;
  Result := RunItflowSearch(Script, Lines);
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

// The tray app's exe (a PyInstaller onefile build) needs the VC++ 2015-2022
// x64 runtime (VCRUNTIME140.dll etc) to load python312.dll at startup. Most
// machines already have it (Windows Update / other software pulls it in),
// but freshly-imaged or minimal machines onboarded via RMM may not, which
// surfaces as "Failed to load Python DLL ... LoadLibrary: The specified
// module could not be found" the first time the app runs. Detect and
// silently install it here so that can't happen.
function VCRedistInstalled(): Boolean;
var
  Version: String;
begin
  Result := RegQueryStringValue(HKLM64, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64',
    'Version', Version) and (Version <> '');
end;

// Updates the "Installing" page's status text so an interactive install
// doesn't look frozen while the redist check/download/install (each a
// blocking Exec call) runs. No-op under /VERYSILENT, where the page is
// never shown.
procedure SetInstallStatus(const Msg: String);
begin
  if not WizardSilent then
  begin
    WizardForm.StatusLabel.Caption := Msg;
    WizardForm.StatusLabel.Repaint;
  end;
end;

// True if InstallVCRedistIfNeeded ran and the runtime still isn't present
// afterward (download failed, e.g. no internet / URL blocked by a
// firewall, or the silent redist install itself failed) - checked at
// ssDone to warn the user instead of failing silently, since ITPanel Pro
// will hit the same "Failed to load Python DLL" error this was meant to
// prevent.
var
  VCRedistStillMissing: Boolean;

procedure InstallVCRedistIfNeeded;
var
  ResultCode: Integer;
  TmpPath, DownloadCmd: String;
begin
  VCRedistStillMissing := False;

  SetInstallStatus('Checking for the Visual C++ Runtime...');
  if VCRedistInstalled() then
    exit;

  SetInstallStatus('Downloading the Visual C++ Runtime (needed to run ITPanel Pro)...');
  TmpPath := ExpandConstant('{tmp}\vc_redist.x64.exe');
  DownloadCmd := '-NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -Uri ''https://aka.ms/vs/17/release/vc_redist.x64.exe'' -OutFile ''' + TmpPath + ''' -UseBasicParsing } catch {}"';

  Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), DownloadCmd, '',
    SW_HIDE, ewWaitUntilTerminated, ResultCode);

  if FileExists(TmpPath) then
  begin
    SetInstallStatus('Installing the Visual C++ Runtime...');
    Exec(TmpPath, '/install /quiet /norestart', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;

  SetInstallStatus('Finishing installation...');
  VCRedistStillMissing := not VCRedistInstalled();
end;

// "Search" on the client box: looks up clients matching the typed text and
// lists them below for the user to click. Requires the Base URL/API Key
// from the previous page to already be filled in.
procedure ClientSearchBtnClick(Sender: TObject);
var
  BaseUrl, ApiKey, Term: String;
  Lines: TStringList;
  I, TabPos: Integer;
begin
  BaseUrl := Trim(ConfigPage.Values[0]);
  ApiKey := Trim(ConfigPage.Values[1]);
  Term := Trim(ClientSearchEdit.Text);

  if (BaseUrl = '') or (BaseUrl = 'https://') or (ApiKey = '') then
  begin
    PickerStatusLabel.Caption := 'Enter the ITFlow Base URL and API Key on the previous page first.';
    exit;
  end;
  if Term = '' then
  begin
    PickerStatusLabel.Caption := 'Type part of the client name to search.';
    exit;
  end;

  PickerStatusLabel.Caption := 'Searching...';
  PickerStatusLabel.Repaint;

  ClientResultsBox.Items.Clear;
  ClientResultIds.Clear;

  Lines := TStringList.Create;
  try
    if not SearchItflowClients(BaseUrl, ApiKey, Term, Lines) then
    begin
      if Lines.Count > 0 then
        PickerStatusLabel.Caption := 'Search failed: ' + Lines[0]
      else
        PickerStatusLabel.Caption := 'Search failed - check the Base URL/API Key and your internet connection.';
      exit;
    end;

    for I := 0 to Lines.Count - 1 do
    begin
      TabPos := Pos(#9, Lines[I]);
      if TabPos = 0 then continue;
      ClientResultIds.Add(Copy(Lines[I], 1, TabPos - 1));
      ClientResultsBox.Items.Add(Copy(Lines[I], TabPos + 1, Length(Lines[I]) - TabPos));
    end;

    if ClientResultsBox.Items.Count = 0 then
      PickerStatusLabel.Caption := 'No clients found matching "' + Term + '".'
    else
      PickerStatusLabel.Caption := IntToStr(ClientResultsBox.Items.Count) + ' client(s) found - select one below.';
  finally
    Lines.Free;
  end;
end;

// Clicking a result fills in the Client ID field on the previous page (the
// same field WriteConfigFile reads), and clears any previously picked
// contact since it belonged to whatever client was selected before.
procedure ClientResultsBoxClick(Sender: TObject);
begin
  if (ClientResultsBox.ItemIndex >= 0) and (ClientResultsBox.ItemIndex < ClientResultIds.Count) then
  begin
    ConfigPage.Values[2] := ClientResultIds[ClientResultsBox.ItemIndex];
    PickerStatusLabel.Caption := 'Selected client: ' + ClientResultsBox.Items[ClientResultsBox.ItemIndex] +
      ' (id ' + ConfigPage.Values[2] + ')';
    ContactResultsBox.Items.Clear;
    ContactResultIds.Clear;
    ConfigPage.Values[3] := '';
  end;
end;

// "Search" on the contact box: scoped to whatever Client ID is currently
// set (manually typed, or from the client search above).
procedure ContactSearchBtnClick(Sender: TObject);
var
  BaseUrl, ApiKey, Term: String;
  ClientId: Integer;
  Lines: TStringList;
  I, TabPos: Integer;
begin
  BaseUrl := Trim(ConfigPage.Values[0]);
  ApiKey := Trim(ConfigPage.Values[1]);
  Term := Trim(ContactSearchEdit.Text);
  ClientId := StrToIntDef(Trim(ConfigPage.Values[2]), 0);

  if ClientId <= 0 then
  begin
    PickerStatusLabel.Caption := 'Pick or enter a Client first.';
    exit;
  end;
  if Term = '' then
  begin
    PickerStatusLabel.Caption := 'Type part of the contact name to search.';
    exit;
  end;

  PickerStatusLabel.Caption := 'Searching...';
  PickerStatusLabel.Repaint;

  ContactResultsBox.Items.Clear;
  ContactResultIds.Clear;

  Lines := TStringList.Create;
  try
    if not SearchItflowContacts(BaseUrl, ApiKey, ClientId, Term, Lines) then
    begin
      if Lines.Count > 0 then
        PickerStatusLabel.Caption := 'Search failed: ' + Lines[0]
      else
        PickerStatusLabel.Caption := 'Search failed - check the Base URL/API Key and your internet connection.';
      exit;
    end;

    for I := 0 to Lines.Count - 1 do
    begin
      TabPos := Pos(#9, Lines[I]);
      if TabPos = 0 then continue;
      ContactResultIds.Add(Copy(Lines[I], 1, TabPos - 1));
      ContactResultsBox.Items.Add(Copy(Lines[I], TabPos + 1, Length(Lines[I]) - TabPos));
    end;

    if ContactResultsBox.Items.Count = 0 then
      PickerStatusLabel.Caption := 'No contacts found matching "' + Term + '".'
    else
      PickerStatusLabel.Caption := IntToStr(ContactResultsBox.Items.Count) + ' contact(s) found - select one below.';
  finally
    Lines.Free;
  end;
end;

procedure ContactResultsBoxClick(Sender: TObject);
begin
  if (ContactResultsBox.ItemIndex >= 0) and (ContactResultsBox.ItemIndex < ContactResultIds.Count) then
  begin
    ConfigPage.Values[3] := ContactResultIds[ContactResultsBox.ItemIndex];
    PickerStatusLabel.Caption := 'Selected contact: ' + ContactResultsBox.Items[ContactResultsBox.ItemIndex] +
      ' (id ' + ConfigPage.Values[3] + ')';
  end;
end;

// Builds the optional "Find Client / Contact" page: two search boxes with
// result lists, laid out under the connection-settings page. Purely
// additive - the Client ID/Contact ID fields on the previous page remain
// the actual source of truth (WriteConfigFile only ever reads those), so a
// layout glitch here can't break a install that just types the IDs in
// directly instead.
procedure CreatePickerPage;
begin
  PickerPage := CreateCustomPage(ConfigPage.ID,
    'Find Client / Contact (optional)',
    'Search ITFlow by name instead of typing numeric IDs - useful when deploying to lots of ' +
    'clients by hand. Skip this page to keep whatever you entered on the previous page.');

  ClientResultIds := TStringList.Create;
  ContactResultIds := TStringList.Create;

  with TNewStaticText.Create(PickerPage) do
  begin
    Parent := PickerPage.Surface;
    Left := 0;
    Top := 0;
    Width := PickerPage.SurfaceWidth;
    Caption := 'Client:';
  end;

  ClientSearchEdit := TNewEdit.Create(PickerPage);
  ClientSearchEdit.Parent := PickerPage.Surface;
  ClientSearchEdit.Left := 0;
  ClientSearchEdit.Top := ScaleY(18);
  ClientSearchEdit.Width := PickerPage.SurfaceWidth - ScaleX(90);

  ClientSearchBtn := TNewButton.Create(PickerPage);
  ClientSearchBtn.Parent := PickerPage.Surface;
  ClientSearchBtn.Left := ClientSearchEdit.Left + ClientSearchEdit.Width + ScaleX(8);
  ClientSearchBtn.Top := ClientSearchEdit.Top - ScaleY(2);
  ClientSearchBtn.Width := ScaleX(82);
  ClientSearchBtn.Height := ClientSearchEdit.Height + ScaleY(4);
  ClientSearchBtn.Caption := '&Search';
  ClientSearchBtn.OnClick := @ClientSearchBtnClick;

  ClientResultsBox := TNewListBox.Create(PickerPage);
  ClientResultsBox.Parent := PickerPage.Surface;
  ClientResultsBox.Left := 0;
  ClientResultsBox.Top := ClientSearchEdit.Top + ClientSearchEdit.Height + ScaleY(6);
  ClientResultsBox.Width := PickerPage.SurfaceWidth;
  ClientResultsBox.Height := ScaleY(70);
  ClientResultsBox.OnClick := @ClientResultsBoxClick;

  with TNewStaticText.Create(PickerPage) do
  begin
    Parent := PickerPage.Surface;
    Left := 0;
    Top := ClientResultsBox.Top + ClientResultsBox.Height + ScaleY(12);
    Width := PickerPage.SurfaceWidth;
    Caption := 'Contact (optional):';
  end;

  ContactSearchEdit := TNewEdit.Create(PickerPage);
  ContactSearchEdit.Parent := PickerPage.Surface;
  ContactSearchEdit.Left := 0;
  ContactSearchEdit.Top := ClientResultsBox.Top + ClientResultsBox.Height + ScaleY(30);
  ContactSearchEdit.Width := PickerPage.SurfaceWidth - ScaleX(90);

  ContactSearchBtn := TNewButton.Create(PickerPage);
  ContactSearchBtn.Parent := PickerPage.Surface;
  ContactSearchBtn.Left := ContactSearchEdit.Left + ContactSearchEdit.Width + ScaleX(8);
  ContactSearchBtn.Top := ContactSearchEdit.Top - ScaleY(2);
  ContactSearchBtn.Width := ScaleX(82);
  ContactSearchBtn.Height := ContactSearchEdit.Height + ScaleY(4);
  ContactSearchBtn.Caption := 'S&earch';
  ContactSearchBtn.OnClick := @ContactSearchBtnClick;

  ContactResultsBox := TNewListBox.Create(PickerPage);
  ContactResultsBox.Parent := PickerPage.Surface;
  ContactResultsBox.Left := 0;
  ContactResultsBox.Top := ContactSearchEdit.Top + ContactSearchEdit.Height + ScaleY(6);
  ContactResultsBox.Width := PickerPage.SurfaceWidth;
  ContactResultsBox.Height := ScaleY(70);
  ContactResultsBox.OnClick := @ContactResultsBoxClick;

  PickerStatusLabel := TNewStaticText.Create(PickerPage);
  PickerStatusLabel.Parent := PickerPage.Surface;
  PickerStatusLabel.Left := 0;
  PickerStatusLabel.Top := ContactResultsBox.Top + ContactResultsBox.Height + ScaleY(12);
  PickerStatusLabel.Width := PickerPage.SurfaceWidth;
  PickerStatusLabel.Caption := '';
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
    'API key: Admin > API Keys. Client ID: on the client''s page in ITFlow, or leave blank and ' +
    'search for it on the next page. Existing settings are pre-filled and kept on upgrades unless changed.');

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

  CreatePickerPage;
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
  end;

  if CurPageID = PickerPage.ID then
  begin
    if (Trim(ConfigPage.Values[2]) = '') or
       (StrToIntDef(Trim(ConfigPage.Values[2]), -1) < 0) then
    begin
      MsgBox('Enter a Client ID on the previous page, or search for and select a client above.', mbError, MB_OK);
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
  begin
    InstallVCRedistIfNeeded;
    WriteConfigFile;
  end;

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

    // Warn rather than fail silently if we couldn't get the VC++ Runtime
    // installed (e.g. no internet access, or the URL is blocked by a
    // firewall) - otherwise ITPanel Pro will hit exactly the
    // "Failed to load Python DLL" error this was meant to prevent, with no
    // clue why. MsgBox is auto-answered (not actually shown) under
    // /SUPPRESSMSGBOXES, so this only surfaces during an interactive run;
    // unattended/RMM deploys get the equivalent check in
    // deploy_itpanelpro.ps1 after the install instead.
    if VCRedistStillMissing then
      MsgBox('ITPanel Pro installed, but the Visual C++ Runtime it needs could not be ' +
        'downloaded or installed automatically (no internet access, or the download URL ' +
        'is blocked). If the app fails to start, install it manually from ' +
        'https://aka.ms/vs/17/release/vc_redist.x64.exe and try again.',
        mbInformation, MB_OK);
  end;
end;
