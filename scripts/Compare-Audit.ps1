<#
.SYNOPSIS
    Builds the before-and-after maintenance report from two audit snapshots.
.DESCRIPTION
    Defaults to the two most recent audit JSON files. Includes the journal of changes and
    cleanups made between the two audits. Writes reports\maintenance-report-<ts>.md.
#>
[CmdletBinding()]
param([string]$Before, [string]$After)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'WinMaint.Common.ps1')
$dataDir = Initialize-WMDataDir

if (-not $Before -or -not $After) {
    $all = @(Get-ChildItem -LiteralPath (Join-Path $dataDir 'reports') -Filter 'audit-*.json' | Sort-Object LastWriteTime)
    if ($all.Count -lt 2) { Write-Output 'Need two audit snapshots (run Invoke-Audit.ps1 before and after).'; exit 1 }
    if (-not $After) { $After = $all[-1].FullName }
    if (-not $Before) { $Before = $all[-2].FullName }
}
$b = Get-Content -LiteralPath $Before -Raw | ConvertFrom-Json
$a = Get-Content -LiteralPath $After -Raw | ConvertFrom-Json

$md = New-Object System.Text.StringBuilder
function L([string]$s = '') { [void]$md.AppendLine($s) }
function Delta([double]$v) { if ($v -ge 0) { "+$(Format-WMBytes $v)" } else { "-$(Format-WMBytes ([math]::Abs($v)))" } }

L '# Windows maintenance report - before and after'
L ''
L "- Before: $($b.startedAt) ($($b.mode)$(if ($b.label) { ", $($b.label)" }))"
L "- After: $($a.startedAt) ($($a.mode)$(if ($a.label) { ", $($a.label)" }))"
L ''

L '## Free space'
L '| Drive | Before | After | Change |'
L '|---|---|---|---|'
foreach ($p in $a.driveFree.PSObject.Properties) {
    $bv = $b.driveFree.($p.Name)
    if ($null -ne $bv) { L "| $($p.Name) | $(Format-WMBytes $bv) | $(Format-WMBytes $p.Value) | $(Delta ([double]$p.Value - [double]$bv)) |" }
}
L ''

if ($b.cleanup -and $a.cleanup) {
    L '## Cleanup targets'
    L '| Target | Before | After | Change |'
    L '|---|---|---|---|'
    $bt = @{}; foreach ($t in $b.cleanup.targets) { $bt[$t.id] = $t }
    foreach ($t in $a.cleanup.targets) {
        $o = $bt[$t.id]; if (-not $o) { continue }
        if ($o.totalBytes -eq 0 -and $t.totalBytes -eq 0) { continue }
        L "| $($t.label) | $(Format-WMBytes $o.totalBytes) | $(Format-WMBytes $t.totalBytes) | $(Delta ([double]$t.totalBytes - [double]$o.totalBytes)) |"
    }
    L ''
}

if ($b.startup -and $a.startup) {
    L "## Startup: $($b.startup.enabledCount) -> $($a.startup.enabledCount) enabled"
    $bs = @{}; foreach ($i in $b.startup.items) { $bs["$($i.source)|$($i.name)"] = $i }
    foreach ($i in $a.startup.items) { $o = $bs["$($i.source)|$($i.name)"]; if ($o -and $o.enabled -ne $i.enabled) { L "- $($i.name) ($($i.source)): $(if ($i.enabled) { 'enabled' } else { 'disabled' })" } }
    L ''
}
if ($b.services -and $a.services) {
    L "## Services: $($b.services.autoStartCount) -> $($a.services.autoStartCount) automatic"
    $bsv = @{}; foreach ($s in $b.services.items) { $bsv[$s.name] = $s }
    foreach ($s in $a.services.items) { $o = $bsv[$s.name]; if ($o -and $o.startMode -ne $s.startMode) { L "- $($s.displayName): $($o.startMode) -> $($s.startMode)" } }
    L ''
}
if ($b.apps -and $a.apps) {
    $removed = @($b.apps.appxCandidates | Where-Object { $n = $_.name; -not @($a.apps.appxCandidates | Where-Object { $_.name -eq $n }).Count })
    L "## Store apps: $($b.apps.appxInstalledCount) -> $($a.apps.appxInstalledCount)"
    foreach ($r in $removed) { L "- Removed: $($r.label) ($($r.name))" }
    L ''
}
if ($b.gaming -and $a.gaming) {
    L '## Gaming settings'
    foreach ($k in 'gameMode', 'hardwareGpuScheduling', 'windowedGameOptimizations') { if ("$($b.gaming.$k)" -ne "$($a.gaming.$k)") { L "- $k : $($b.gaming.$k) -> $($a.gaming.$k)" } }
    if ($b.gaming.powerPlan.activeName -ne $a.gaming.powerPlan.activeName) { L "- Power plan: $($b.gaming.powerPlan.activeName) -> $($a.gaming.powerPlan.activeName)" }
    L ''
}

# Only compare findings from sections both audits ran; otherwise "not checked" would look "resolved".
$areaSection = @{ updates = 'drivers'; network = 'gaming' }
$common = @($b.sections | Where-Object { @($a.sections) -contains $_ })
$inScope = { param($f) $sec = if ($areaSection.ContainsKey($f.area)) { $areaSection[$f.area] } else { $f.area }; ($common -contains $sec) -or ($f.area -eq 'security' -and ($common -contains 'gaming')) }
$bf = @($b.findings | Where-Object { & $inScope $_ }); $af = @($a.findings | Where-Object { & $inScope $_ })
$sev = { param($x) @{ high = @($x | Where-Object severity -eq 'high').Count; medium = @($x | Where-Object severity -eq 'medium').Count; total = @($x).Count } }
$sb = & $sev $bf; $sa = & $sev $af
L "## Findings in sections both audits checked ($($common -join ', ')): $($sb.total) -> $($sa.total) (high $($sb.high) -> $($sa.high), medium $($sb.medium) -> $($sa.medium))"
$aTitles = @($af | ForEach-Object title); $bTitles = @($bf | ForEach-Object title)
foreach ($f in $bf | Where-Object { $aTitles -notcontains $_.title }) { L "- Resolved: $($f.title)" }
foreach ($f in $af | Where-Object { $bTitles -notcontains $_.title }) { L "- New/changed: $($f.title)" }
$skipped = @($b.sections | Where-Object { @($a.sections) -notcontains $_ })
if ($skipped.Count) { L "- Not re-checked in the after audit: $($skipped -join ', ') (their findings still stand)" }
L ''

$from = [datetime]$b.finishedAt; $to = [datetime]$a.startedAt
$acts = @(Get-WMJournal | Where-Object { $_.time -and ([datetime]$_.time) -ge $from -and ([datetime]$_.time) -le $to })
L "## Actions taken between audits ($($acts.Count))"
foreach ($e in $acts) {
    $what = switch ($e.kind) {
        'clean' { "Cleaned $($e.target): $(Format-WMBytes $e.freedBytes)" }
        'backup' { "Configuration backup: $($e.path)" }
        'restore-point' { "Restore point #$($e.sequence): $($e.description)" }
        'undo' { "Undid change $($e.undoes) ($($e.name))" }
        default { "$($e.action) $($e.name) (journal id $($e.id))" }
    }
    L "- $(([datetime]$e.time).ToString('yyyy-MM-dd HH:mm')) - $what"
}
L ''
L 'Reversible changes can be listed with `Undo-Change.ps1 -List`.'

$out = Join-Path $dataDir ("reports\maintenance-report-$(Get-WMTimestamp).md")
$md.ToString() | Set-Content -LiteralPath $out -Encoding UTF8
Write-Output $md.ToString()
Write-Output "REPORT_MD: $out"
