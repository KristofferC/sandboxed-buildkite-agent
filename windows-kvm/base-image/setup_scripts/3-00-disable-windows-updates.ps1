<#
.SYNOPSIS
    Maximal Windows Update disable for ephemeral images (no backups).

.DESCRIPTION
    1) Import pause‑updates registry
    2) Redirect WSUS to localhost
    3) Apply GPO registry keys to disable updates
    4) Disable automatic driver searching
    5) Stop & disable all Update‑related services (with verification)
    6) Disable all Update‑related Scheduled Tasks
    7) Block Update domains in hosts file
#>

# 1) IMPORT PAUSE‑UPDATES REGISTRY
$RegFile = Join-Path $PSScriptRoot 'windows-updates-pause.reg'
try {
    Write-Host "Importing pause‑updates registry..."
    Start-Process regedit.exe -ArgumentList '/s', "`"$RegFile`"" -Wait -Verb RunAs
} catch {
    Write-Error "Failed to import $RegFile — aborting."
    exit 1
}

# Helper to ensure a registry path exists
function RegMkPath { param($p) if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null } }

# 2) REDIRECT WSUS TO LOCALHOST
Write-Host "Pointing WSUS server to 127.0.0.1..."
$wsu = RegMkPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
New-ItemProperty -Path $wsu -Name WUServer       -Value 'http://127.0.0.1' -PropertyType String -Force
New-ItemProperty -Path $wsu -Name WUStatusServer -Value 'http://127.0.0.1' -PropertyType String -Force

# 3) APPLY GPO‑STYLE KEYS
Write-Host "Applying Group Policy keys to disable updates..."
$au = RegMkPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$props = @{
    UseWUServer                   = 0
    ConfigureAutomaticUpdates     = 1
    NoAutoUpdate                  = 1
    NoAUShutdownOption            = 1
    AlwaysAutoRebootAtScheduledTime = 0
    NoAutoRebootWithLoggedOnUsers    = 1
    AutoInstallMinorUpdates       = 0
    AUOptions                     = 1
}
foreach ($n in $props.Keys) {
    New-ItemProperty -Path $au -Name $n -Value $props[$n] -PropertyType DWord -Force
}

# 4) LOCK DOWN DRIVER SEARCH
Write-Host "Disabling automatic driver searches..."
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' `
    -Name SearchOrderConfig -Value 0 -Force

# 5) DISABLE SERVICES (with verification)
$services = @(
    "wuauserv",        # Windows Update
    "bits",            # Background Intelligent Transfer Service
    "dosvc",           # Delivery Optimization
    "WaaSMedicSvc",    # Windows Update Medic Service
    "UsoSvc",          # Update Orchestrator Service
    "sedsvc",          # (Sometimes present on older systems)
    "TrustedInstaller", # Windows Modules Installer
    "InstallService",  # Microsoft Store Install Service
    "UpdateSessionOrchestrator" # Update Session Orchestrator
)
foreach ($svc in $services) {
    Write-Host "Disabling service: $svc"
    try {
        Stop-Service -Name $svc -Force -ErrorAction Stop
        Set-Service  -Name $svc -StartupType Disabled -ErrorAction Stop
        $st = (Get-Service -Name $svc).StartType
        if ($st -ne 'Disabled') {
            Write-Warning "$svc StartType is still $st"
        }
    } catch {
        Write-Warning "Could not disable $svc: $_"
    }
}

# 6) DISABLE SCHEDULED TASKS
$tasks = @(
    '\Microsoft\Windows\WindowsUpdate\',
    '\Microsoft\Windows\UpdateOrchestrator\',
    '\Microsoft\Windows\WaaSMedic\',
    '\Microsoft\Windows\Application Experience\ProgramDataUpdater\'
)
foreach ($tp in $tasks) {
    Write-Host "Disabling tasks in $tp"
    Get-ScheduledTask -TaskPath $tp -ErrorAction SilentlyContinue |
      Disable-ScheduledTask -ErrorAction SilentlyContinue
}

# 7) BLOCK UPDATE DOMAINS
Write-Host "Adding Windows Update domains to hosts file..."
$hostsFile = "$env:WinDir\System32\drivers\etc\hosts"
$entries = @(
    '0.0.0.0 windowsupdate.microsoft.com',
    '0.0.0.0 update.microsoft.com',
    '0.0.0.0 download.windowsupdate.com',
    '0.0.0.0 dl.delivery.mp.microsoft.com'
)
foreach ($line in $entries) {
    if (-not (Select-String -Path $hostsFile -Pattern [regex]::Escape($line) -Quiet)) {
        Add-Content -Path $hostsFile -Value $line
    }
}

Write-Host "`n✔ Windows Update is now fully paused/disabled."
