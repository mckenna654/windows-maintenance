<#
.SYNOPSIS
    Cleans approved catalog targets for the windows-maintenance skill.
.DESCRIPTION
    DRY RUN BY DEFAULT. Deletes nothing unless -Execute is passed.
    Only ids from config\clean-targets.json can be cleaned; every root is re-checked
    against config\protected.json immediately before deletion; reparse points are never
    followed; locked/in-use files are skipped; apps that must be closed are never killed.
.PARAMETER Targets
    Catalog ids (e.g. user-temp, edge-cache) or the keyword 'tier1' for every tier-1 target.
.PARAMETER Execute
    Actually delete. Without it the script only re-measures and prints the plan.
.PARAMETER AllowTier3
    Required for tier-3 targets (e.g. recycle-bin). Use only after a per-item user approval.
.EXAMPLE
    Invoke-Clean.ps1 -Targets user-temp,edge-cache            # dry run
    Invoke-Clean.ps1 -Targets user-temp,edge-cache -Execute   # after approval
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$Targets,
    [switch]$Execute,
    [switch]$AllowTier3,
    [int]$MaxSecondsPerPath = 300
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'WinMaint.Common.ps1')

$catalog = Get-WMConfig 'clean-targets'
$isAdmin = Test-WMAdmin
$byId = @{}; foreach ($t in $catalog.targets) { $byId[$t.id] = $t }

$ids = New-Object System.Collections.Generic.List[string]
foreach ($raw in $Targets) {
    foreach ($id in ($raw -split ',')) {
        $id = $id.Trim()
        if (-not $id) { continue }
        if ($id -eq 'tier1') { foreach ($t in $catalog.targets) { if ($t.tier -eq 1 -and $t.method -ne 'report-only' -and -not $ids.Contains($t.id)) { $ids.Add($t.id) } } }
        elseif (-not $ids.Contains($id)) { $ids.Add($id) }
    }
}

$runId = Get-WMTimestamp
$freeBefore = Get-WMDriveFree
$results = New-Object System.Collections.Generic.List[object]
Write-Host ("windows-maintenance clean - {0} - {1}" -f $(if ($Execute) { 'EXECUTE' } else { 'DRY RUN (nothing will be deleted)' }), $(if ($isAdmin) { 'elevated' } else { 'standard user' })) -ForegroundColor Cyan

function Add-Result([string]$Id, [string]$Status, [string]$Detail, [int64]$Before = 0, [int64]$Freed = 0, $Extra = $null) {
    $r = [ordered]@{ id = $Id; status = $Status; detail = $Detail; estimatedBytes = $Before; freedBytes = $Freed }
    if ($Extra) { foreach ($k in $Extra.Keys) { $r[$k] = $Extra[$k] } }
    $results.Add([pscustomobject]$r)
    $color = switch -Wildcard ($Status) { 'cleaned' { 'Green' } 'would-clean' { 'Yellow' } 'skipped*' { 'DarkYellow' } 'refused*' { 'Red' } 'error' { 'Red' } default { 'Gray' } }
    Write-Host ("  [{0}] {1}: {2}{3}" -f $Status, $Id, $Detail, $(if ($Freed) { " (freed $(Format-WMBytes $Freed))" } elseif ($Before) { " (~$(Format-WMBytes $Before))" } else { '' })) -ForegroundColor $color
}

function Measure-Spec($t, [int]$minAge) {
    $spec = @(); if ($t.paths) { $spec += $t.paths }; if ($t.measurePaths) { $spec += $t.measurePaths }
    $sum = [int64]0
    foreach ($p in (Resolve-WMPaths $spec)) { $sum += (Measure-WMPath $p $minAge 30).EligibleBytes }
    return $sum
}

foreach ($id in $ids) {
    $t = $byId[$id]
    if (-not $t) { Add-Result $id 'refused-unknown' 'not in the cleanup catalog; only catalog targets can be cleaned'; continue }
    if ($t.method -eq 'report-only') { Add-Result $id 'manual' "report-only target. $($t.note)"; continue }
    if ($t.tier -ge 3 -and -not $AllowTier3) { Add-Result $id 'refused-tier3' 'tier-3 target needs -AllowTier3 after an explicit per-item approval'; continue }
    if ($t.scope -eq 'admin' -and -not $isAdmin) { Add-Result $id 'skipped-needs-admin' 'ELEVATION_REQUIRED: re-run this target from an elevated PowerShell'; continue }
    if ($t.requiresClosed) {
        $running = Get-WMRunningProcesses ([string[]]$t.requiresClosed)
        if ($running.Count) { Add-Result $id 'skipped-app-open' "close $($running -join ', ') first (this skill never force-closes apps)"; continue }
    }
    $minAge = if ($null -ne $t.minAgeDays) { [int]$t.minAgeDays } else { 0 }

    try {
        switch ($t.method) {
            'files-older-than' {
                $roots = Resolve-WMPaths ([string[]]$t.paths)
                if (-not $roots.Count) { Add-Result $id 'nothing-to-do' 'no matching folders'; break }
                $est = [int64]0; $freed = [int64]0; $locked = [int64]0; $errs = 0; $refused = @(); $trunc = $false
                foreach ($root in $roots) {
                    $why = Test-WMCleanRoot $root
                    if ($why) { $refused += $why; continue }
                    $est += (Measure-WMPath $root $minAge 30).EligibleBytes
                    if ($Execute) {
                        $r = Remove-WMContents $root $minAge ([string[]]$t.excludeNames) $MaxSecondsPerPath
                        $freed += $r.DeletedBytes; $locked += $r.SkippedLocked; $errs += $r.Errors
                        if ($r.Truncated) { $trunc = $true }
                    }
                }
                if ($refused.Count -and -not $est) { Add-Result $id 'refused-protected' ($refused -join '; '); break }
                if ($Execute) {
                    $detail = "$($roots.Count) folder(s); files older than $minAge day(s)"
                    if ($locked) { $detail += "; $locked in-use file(s) skipped" }
                    if ($errs) { $detail += "; $errs error(s)" }
                    if ($trunc) { $detail += '; stopped at time limit (run again to continue)' }
                    if ($refused.Count) { $detail += "; refused: $($refused -join '; ')" }
                    Add-Result $id 'cleaned' $detail $est $freed @{ roots = $roots; skippedLocked = $locked }
                } else {
                    Add-Result $id 'would-clean' "$($roots.Count) folder(s): $($roots -join '; ')" $est
                }
            }
            'file' {
                $files = Resolve-WMPaths ([string[]]$t.paths)
                if (-not $files.Count) { Add-Result $id 'nothing-to-do' 'file not present'; break }
                $f = Get-Item -LiteralPath $files[0] -Force
                $why = Test-WMCleanRoot $f.FullName
                if ($why) { Add-Result $id 'refused-protected' $why; break }
                if ($f.LastWriteTime -gt (Get-Date).AddDays(-$minAge)) { Add-Result $id 'skipped-too-new' "newer than $minAge days" $f.Length; break }
                if ($Execute) { $len = $f.Length; Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; Add-Result $id 'cleaned' $f.FullName $len $len }
                else { Add-Result $id 'would-clean' $f.FullName $f.Length }
            }
            'tool-command' {
                $exe = Get-Command $t.command.exe -ErrorAction SilentlyContinue
                if (-not $exe) { Add-Result $id 'skipped-no-tool' "$($t.command.exe) is not on PATH"; break }
                $cmdText = "$($t.command.exe) $($t.command.args -join ' ')"
                if ($t.measurePaths -and @($t.measurePaths).Count -and -not (Resolve-WMPaths ([string[]]$t.measurePaths)).Count) { Add-Result $id 'nothing-to-do' 'cache folder not present'; break }
                $before = Measure-Spec $t 0
                if (-not $Execute) { Add-Result $id 'would-clean' "would run: $cmdText" $before; break }
                $cargs = [string[]]$t.command.args
                $output = & $exe.Source @cargs 2>&1 | Out-String
                $code = $LASTEXITCODE
                $after = Measure-Spec $t 0
                $status = if ($code -eq 0) { 'cleaned' } elseif ($after -lt $before) { 'partial' } else { 'error' }
                Add-Result $id $status "ran: $cmdText (exit $code)" $before ([math]::Max([int64]0, $before - $after)) @{ output = ($output.Trim() -split "`n" | Select-Object -Last 5) -join ' / ' }
            }
            'delivery-optimization' {
                $before = Measure-Spec $t 0
                if (-not $Execute) { Add-Result $id 'would-clean' 'would run: Delete-DeliveryOptimizationCache -Force' $before; break }
                Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
                $after = Measure-Spec $t 0
                Add-Result $id 'cleaned' 'Delete-DeliveryOptimizationCache' $before ([math]::Max([int64]0, $before - $after))
            }
            'dism-component-cleanup' {
                if (-not $Execute) { Add-Result $id 'would-clean' 'would run: DISM /Online /Cleanup-Image /StartComponentCleanup (no /ResetBase)'; break }
                $c0 = (Get-WMDriveFree)[$env:SystemDrive]
                $o = & DISM.exe /Online /Cleanup-Image /StartComponentCleanup /English 2>&1 | Out-String
                $code = $LASTEXITCODE
                $c1 = (Get-WMDriveFree)[$env:SystemDrive]
                Add-Result $id $(if ($code -eq 0) { 'cleaned' } else { 'error' }) "DISM StartComponentCleanup exit $code" 0 ([math]::Max([int64]0, $c1 - $c0)) @{ output = (($o.Trim() -split "`n") | Select-Object -Last 3) -join ' / ' }
            }
            'recycle-bin' {
                $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
                $before = [int64]0
                foreach ($d in [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }) {
                    $rb = Join-Path $d.RootDirectory.FullName "`$Recycle.Bin\$sid"
                    if (Test-Path -LiteralPath $rb) { $before += (Measure-WMPath $rb 0 30).TotalBytes }
                }
                if (-not $Execute) { Add-Result $id 'would-clean' 'would permanently delete everything in the Recycle Bin (all drives)' $before; break }
                Clear-RecycleBin -Force -ErrorAction Stop
                Add-Result $id 'cleaned' 'Recycle Bin emptied' $before $before
            }
            default { Add-Result $id 'error' "unknown method $($t.method)" }
        }
    } catch {
        Add-Result $id 'error' $_.Exception.Message
    }
}

$freeAfter = Get-WMDriveFree
$freedTotal = [int64](($results | Measure-Object -Property freedBytes -Sum).Sum)
$estTotal = [int64](($results | Measure-Object -Property estimatedBytes -Sum).Sum)
$driveDelta = [ordered]@{}; foreach ($k in $freeAfter.Keys) { if ($freeBefore.Contains($k)) { $driveDelta[$k] = [int64]$freeAfter[$k] - [int64]$freeBefore[$k] } }

$summary = [ordered]@{
    runId = $runId; executed = [bool]$Execute; elevated = $isAdmin; time = (Get-Date).ToString('o')
    targets = $results.ToArray(); estimatedBytes = $estTotal; freedBytes = $freedTotal
    driveFreeBefore = $freeBefore; driveFreeAfter = $freeAfter; driveFreeDelta = $driveDelta
}
$dataDir = Initialize-WMDataDir
$resPath = Join-Path $dataDir ("results\clean-$runId-$(if ($Execute) { 'executed' } else { 'dryrun' }).json")
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resPath -Encoding UTF8

if ($Execute) {
    foreach ($r in $results | Where-Object { $_.status -eq 'cleaned' }) {
        [void](Write-WMJournal @{ kind = 'clean'; runId = $runId; target = $r.id; freedBytes = $r.freedBytes; undoable = $false })
    }
    Write-Host ''
    Write-Host "Freed (sum of deleted files): $(Format-WMBytes $freedTotal)   Estimated beforehand: $(Format-WMBytes $estTotal)" -ForegroundColor Cyan
    Write-Host ("Drive free-space change: " + (($driveDelta.GetEnumerator() | ForEach-Object { "$($_.Key) {0}{1}" -f $(if ($_.Value -ge 0) { '+' } else { '-' }), (Format-WMBytes ([math]::Abs($_.Value))) }) -join ', '))
} else {
    Write-Host ''
    Write-Host "Dry run total: ~$(Format-WMBytes $estTotal). Re-run with -Execute after the user approves these exact targets." -ForegroundColor Cyan
}
Write-Output "CLEAN_RESULT: $resPath"
