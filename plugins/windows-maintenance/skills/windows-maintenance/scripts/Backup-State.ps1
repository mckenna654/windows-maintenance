<#
.SYNOPSIS
    Snapshots the configuration this skill can change, before any change is applied.
.DESCRIPTION
    Read-only with respect to the system: exports registry keys, service start types, Store
    apps, programs, non-Microsoft scheduled tasks and the active power plan into
    %LOCALAPPDATA%\WindowsMaintenance\backups\<timestamp>. Works without elevation
    (HKLM keys are read-only exports).
#>
[CmdletBinding()]
param([string]$Reason = 'pre-change backup')
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'WinMaint.Common.ps1')

$dir = Join-Path (Initialize-WMDataDir) ("backups\" + (Get-WMTimestamp))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$done = New-Object System.Collections.Generic.List[string]

$regs = [ordered]@{
    'hkcu-run.reg'               = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'
    'hkcu-startupapproved.reg'   = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    'hklm-run.reg'               = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Run'
    'hklm-run32.reg'             = 'HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    'hklm-startupapproved.reg'   = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    'hkcu-gamebar.reg'           = 'HKCU\Software\Microsoft\GameBar'
    'hkcu-gamedvr.reg'           = 'HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR'
    'hkcu-directx-userprefs.reg' = 'HKCU\Software\Microsoft\DirectX\UserGpuPreferences'
}
foreach ($f in $regs.Keys) {
    & reg.exe export $regs[$f] (Join-Path $dir $f) /y 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $done.Add($f) }
}

Get-CimInstance Win32_Service | Select-Object Name, DisplayName, StartMode, DelayedAutoStart, State, PathName |
    Export-Csv -LiteralPath (Join-Path $dir 'services.csv') -NoTypeInformation -Encoding UTF8; $done.Add('services.csv')
try { Get-AppxPackage | Select-Object Name, PackageFullName, PackageFamilyName, Version, IsFramework, NonRemovable, InstallLocation |
    Export-Csv -LiteralPath (Join-Path $dir 'appx-packages.csv') -NoTypeInformation -Encoding UTF8; $done.Add('appx-packages.csv') } catch { }
Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object DisplayName | Select-Object DisplayName, DisplayVersion, Publisher, InstallDate, UninstallString |
    Export-Csv -LiteralPath (Join-Path $dir 'programs.csv') -NoTypeInformation -Encoding UTF8; $done.Add('programs.csv')
try { Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } | Select-Object TaskPath, TaskName, State |
    Export-Csv -LiteralPath (Join-Path $dir 'scheduled-tasks.csv') -NoTypeInformation -Encoding UTF8; $done.Add('scheduled-tasks.csv') } catch { }

(powercfg /list) | Set-Content -LiteralPath (Join-Path $dir 'powercfg-list.txt') -Encoding UTF8
$active = [regex]::Match((powercfg /getactivescheme | Out-String), '([0-9a-fA-F-]{36})').Groups[1].Value
if ($active) { & powercfg /export (Join-Path $dir "powerplan-$active.pow") $active 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { $done.Add("powerplan-$active.pow") } }
$done.Add('powercfg-list.txt')

[ordered]@{ time = (Get-Date).ToString('o'); reason = $Reason; files = $done.ToArray(); activePowerPlan = $active } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'manifest.json') -Encoding UTF8
[void](Write-WMJournal @{ kind = 'backup'; path = $dir; reason = $Reason; undoable = $false })
Write-Output "Backed up $($done.Count) items."
Write-Output "BACKUP_DIR: $dir"
