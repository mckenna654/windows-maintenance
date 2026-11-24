<#
.SYNOPSIS
    Creates (and verifies) a System Restore point before changes. Requires elevation.
.DESCRIPTION
    Uses the SystemRestore WMI class (works in Windows PowerShell 5.1 and PowerShell 7).
    Windows silently skips creation if another restore point was made in the last 24 hours;
    this script detects that and reports the existing point instead of claiming success.
    -EnableSystemProtection turns System Protection on for the system drive first. That is a
    system setting change: use it only after the user approves it.
#>
[CmdletBinding()]
param(
    [string]$Description = 'windows-maintenance: before changes',
    [switch]$EnableSystemProtection
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WinMaint.Common.ps1')
if (-not (Test-WMAdmin)) { Write-WMElevationRequired 'Creating a restore point'; exit 2 }

$drive = "$env:SystemDrive\"
function Get-Points { @(Get-CimInstance -Namespace root/default -ClassName SystemRestore -ErrorAction SilentlyContinue) }
function Get-PointTime($p) { [Management.ManagementDateTimeConverter]::ToDateTime($p.CreationTime) }

if ($EnableSystemProtection) {
    $r = Invoke-CimMethod -Namespace root/default -ClassName SystemRestore -MethodName Enable -Arguments @{ Drive = $drive }
    if ($r.ReturnValue -ne 0) { Write-Output "RESTORE_POINT: failed to enable System Protection on $drive (code $($r.ReturnValue))"; exit 1 }
    [void](Write-WMJournal @{ kind = 'system-protection'; action = 'enable'; drive = $drive; undoable = $false })
    Write-Output "System Protection enabled on $drive."
}

$before = Get-Points
$maxBefore = [uint32](($before | Measure-Object -Property SequenceNumber -Maximum).Maximum)
$res = Invoke-CimMethod -Namespace root/default -ClassName SystemRestore -MethodName CreateRestorePoint -Arguments @{ Description = $Description; RestorePointType = [uint32]12; EventType = [uint32]100 }

if ($res.ReturnValue -ne 0) {
    $hint = if ($res.ReturnValue -eq 1058) { 'System Protection appears to be off for the system drive. Ask the user, then re-run with -EnableSystemProtection.' } else { 'See https://learn.microsoft.com/windows/win32/sr/createrestorepoint-systemrestore for the code.' }
    Write-Output "RESTORE_POINT: FAILED (code $($res.ReturnValue)). $hint"
    exit 1
}
# Windows can take a while to list a new point, so poll before concluding it was skipped.
$new = $null
for ($i = 0; $i -lt 30 -and -not $new; $i++) {
    $after = Get-Points
    $new = $after | Where-Object { $_.SequenceNumber -gt $maxBefore } | Sort-Object SequenceNumber -Descending | Select-Object -First 1
    if (-not $new) { Start-Sleep -Seconds 3 }
}
if ($new) {
    [void](Write-WMJournal @{ kind = 'restore-point'; sequence = $new.SequenceNumber; description = $new.Description; undoable = $false })
    Write-Output "RESTORE_POINT: CREATED #$($new.SequenceNumber) '$($new.Description)' at $((Get-PointTime $new).ToString('yyyy-MM-dd HH:mm'))"
    exit 0
}
$latest = $after | Sort-Object SequenceNumber -Descending | Select-Object -First 1
if ($latest -and ((Get-Date) - (Get-PointTime $latest)).TotalHours -lt 24) {
    $t = Get-PointTime $latest
    Write-Output "RESTORE_POINT: SKIPPED_BY_WINDOWS - a restore point already exists from $($t.ToString('yyyy-MM-dd HH:mm')) ('$($latest.Description)'). Windows allows one per 24 hours by default. That point predates the changes and can be used to roll back."
    exit 0
}
Write-Output 'RESTORE_POINT: UNKNOWN - Windows reported success but no restore point is listed. Check System Protection settings (SystemPropertiesProtection.exe).'
exit 1
