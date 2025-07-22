# We don't want our downstream images to be installing windows updates, EVER.
# So we set the Windows Update server to localhost, which breaks it nicely.

# Helper function to avoid having to create root keys all the time
function RegMkPath()
{
    Param($Path)
    if (-NOT (Test-Path $Path)) {
        New-Item -Path $Path -Force
    }
    return $Path
}

Write-Output " -> Disabling Windows Update..."

# First, apply registry changes to pause updates and set policies
$RegFilePath = Join-Path -Path $PSScriptRoot -ChildPath "windows-updates-pause.reg"
Start-Process -FilePath "regedit.exe" -ArgumentList "/s", "`"$RegFilePath`"" -Wait -Verb RunAs

# Then apply additional registry policies
$RegPath = RegMkPath -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
New-ItemProperty -Path $RegPath -Name "WUServer" -Value "http://127.0.0.1" -PropertyType STRING -Force
New-ItemProperty -Path $RegPath -Name "WUStatusServer" -Value "http://127.0.0.1" -PropertyType STRING -Force

$RegPath = RegMkPath -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
New-ItemProperty -Path $RegPath -Name "UseWUServer" -Value 1 -PropertyType DWORD -Force
New-ItemProperty -Path $RegPath -Name "NoAutoUpdate" -Value 1 -PropertyType DWORD -Force
New-ItemProperty -Path $RegPath -Name "AUOptions" -Value 1 -PropertyType DWORD -Force

$RegPath = RegMkPath -Path "HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv"
New-ItemProperty -Path $RegPath -Name "Start" -Value 4 -PropertyType DWORD -Force
$RegPath = RegMkPath -Path "HKLM:\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc"
New-ItemProperty -Path $RegPath -Name "Start" -Value 4 -PropertyType DWORD -Force

$RegPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching"
Set-ItemProperty -Path $RegPath -Name "SearchOrderConfig" -Value 0 -PropertyType DWORD -Force

# Disable Windows Update Services
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

foreach ($service in $services) {
    Write-Host "Disabling service: $service"
    try {
        Stop-Service -Name $service -Force -ErrorAction Stop
        Set-Service -Name $service -StartupType Disabled -ErrorAction Stop

        # Verify the service is actually disabled
        $svc = Get-Service -Name $service -ErrorAction SilentlyContinue
        if ($svc -and $svc.StartType -ne "Disabled") {
            Write-Warning "Failed to disable service: $service (StartType: $($svc.StartType))"
        } else {
            Write-Host "Successfully disabled service: $service"
        }
    } catch {
        Write-Warning "Error handling service $service`: $_"
    }
}

# Disable all Windows Update-related scheduled tasks
Get-ScheduledTask -TaskPath '\Microsoft\Windows\WindowsUpdate\'  | Disable-ScheduledTask
Get-ScheduledTask -TaskPath '\Microsoft\Windows\UpdateOrchestrator\'  | Disable-ScheduledTask
