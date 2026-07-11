<#
.SYNOPSIS
    Deploys ITPanel Pro via TacticalRMM by silently running the
    Inno Setup installer with per-client configuration.

.DESCRIPTION
    Downloads ITPanelProSetup.exe and runs it with /VERYSILENT,
    passing the ITFlow connection settings as install parameters. The
    installer writes C:\ProgramData\ITPanelPro\config.json,
    installs the app to C:\Program Files\ITPanelPro, and adds an
    All Users Startup shortcut. If a previous "ITFlow Quick Ticket" install
    is found, it is silently removed and its config is migrated.

.NOTES
    Run as a TacticalRMM script with type "powershell", running as System.

    Expected script arguments (in order):
        1. InstallerUrl   - URL to download ITPanelProSetup.exe from
                             (e.g. attached to a GitHub release)
        2. ItflowBaseUrl  - e.g. https://itflow.foleyit.com
        3. ApiKey         - ITFlow API key (Admin > API Keys)
        4. ClientId       - ITFlow client_id for this client
        5. ContactId      - (optional) ITFlow contact_id, or 0/blank
        6. Priority       - (optional) Low/Medium/High/Critical, default Medium
#>

param(
    [Parameter(Mandatory = $true)] [string]$InstallerUrl,
    [Parameter(Mandatory = $true)] [string]$ItflowBaseUrl,
    [Parameter(Mandatory = $true)] [string]$ApiKey,
    [Parameter(Mandatory = $true)] [int]$ClientId,
    [int]$ContactId = 0,
    [string]$Priority = "Medium"
)

$ErrorActionPreference = "Stop"

$installerPath = Join-Path $env:TEMP "ITPanelProSetup.exe"

Write-Host "Downloading installer from $InstallerUrl ..."
Invoke-WebRequest -Uri $InstallerUrl -OutFile $installerPath -UseBasicParsing

$contactArg = if ($ContactId -gt 0) { $ContactId } else { "" }

$installerArgs = @(
    "/VERYSILENT",
    "/SUPPRESSMSGBOXES",
    "/NORESTART",
    "/ItflowBaseUrl=$ItflowBaseUrl",
    "/ApiKey=$ApiKey",
    "/ClientId=$ClientId",
    "/ContactId=$contactArg",
    "/Priority=$Priority"
)

Write-Host "Running installer silently (first install can take a minute or two if the Visual C++ Runtime needs to be downloaded)..."
$proc = Start-Process -FilePath $installerPath -ArgumentList $installerArgs -PassThru

# Start-Process -Wait gives no output until the process exits, which on a slow
# link (waiting on the VC++ redist download inside the installer) looks
# indistinguishable from a hung job in the RMM log. Poll instead so there's a
# periodic heartbeat proving it's still working.
$elapsed = 0
while (-not $proc.HasExited) {
    Start-Sleep -Seconds 15
    $elapsed += 15
    Write-Host "Still installing... (${elapsed}s elapsed)"
}
Write-Host "Installer exit code: $($proc.ExitCode)"

# The installer's own "VC++ Runtime couldn't be installed" warning is a
# MsgBox, which /SUPPRESSMSGBOXES auto-answers without ever showing - so it
# never reaches this job's log. Do the same registry check here instead,
# so a client stuck without the runtime (no internet, blocked URL) is
# flagged now rather than discovered later as a silent "app won't start".
$vcRedistKey = "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64"
if (-not (Test-Path $vcRedistKey)) {
    Write-Host "WARNING: Visual C++ Runtime not detected after install - ITPanel Pro may fail to start with 'Failed to load Python DLL'. Install it manually: https://aka.ms/vs/17/release/vc_redist.x64.exe"
}

Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue

# Launch now for the active interactive session, if any (the installer's
# /SUPPRESSMSGBOXES + silent flags skip the "launch now" prompt)
try {
    $exePath = "C:\Program Files\ITPanelPro\ITPanelPro.exe"
    $explorer = Get-Process -Name explorer -IncludeUserName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($explorer -and (Test-Path $exePath)) {
        Start-Process -FilePath $exePath
        Write-Host "Launched ITPanelPro.exe"
    } else {
        Write-Host "No interactive session detected; app will start on next login."
    }
} catch {
    Write-Host "Could not auto-launch app (will start on next login): $_"
}

if ($proc.ExitCode -ne 0) {
    throw "Installer failed with exit code $($proc.ExitCode)"
}

Write-Host "ITPanel Pro deployment complete."
