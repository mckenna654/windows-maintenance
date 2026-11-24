<#
.SYNOPSIS
    Lists or reverses changes recorded by Invoke-Change.ps1.
.DESCRIPTION
    -List shows undoable journal entries that have not been undone.
    -Id <id>[,<id>] reverses specific entries. -All reverses every outstanding entry (newest first).
    Dry run unless -Execute. Cleanups (deleted files) are not reversible and are not listed.
#>
[CmdletBinding()]
param(
    [switch]$List,
    [string[]]$Id = @(),
    [switch]$All,
    [switch]$Execute
)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'WinMaint.Common.ps1')
$isAdmin = Test-WMAdmin

$journal = Get-WMJournal
$undone = @{}; foreach ($e in $journal | Where-Object { $_.kind -eq 'undo' }) { $undone[$e.undoes] = $true }
$open = @($journal | Where-Object { $_.undoable -and -not $undone.ContainsKey($_.id) })

if ($List -or (-not $Id.Count -and -not $All)) {
    if (-not $open.Count) { Write-Output 'No outstanding reversible changes.'; return }
    $open | Sort-Object time -Descending | ForEach-Object { [pscustomobject]@{ id = $_.id; time = $_.time; kind = $_.kind; action = $_.action; name = $_.name } } | Format-Table -AutoSize | Out-String -Width 200
    return
}

$targets = if ($All) { $open | Sort-Object time -Descending } else { @($open | Where-Object { ($Id -split ',') -contains $_.id }) }
if (-not $targets.Count) { Write-Output 'Nothing matched.'; return }

foreach ($e in $targets) {
    $desc = "$($e.kind) $($e.action) $($e.name)"
    if (-not $Execute) { Write-Output "UNDO_PLAN: [$($e.id)] would reverse $desc"; continue }
    try {
        switch ($e.kind) {
            'startup-approved' {
                if ($e.approvedKey -like 'HKLM:*' -and -not $isAdmin) { throw 'ELEVATION_REQUIRED' }
                if ($e.previousBase64) { Set-ItemProperty -LiteralPath $e.approvedKey -Name $e.name -Value ([Convert]::FromBase64String($e.previousBase64)) -Type Binary }
                else { Remove-ItemProperty -LiteralPath $e.approvedKey -Name $e.name -ErrorAction SilentlyContinue }
            }
            'startup-task' {
                if (-not $isAdmin) { throw 'ELEVATION_REQUIRED' }
                if ($e.previousState -eq 'Disabled') { Disable-ScheduledTask -TaskPath $e.taskPath -TaskName $e.name | Out-Null } else { Enable-ScheduledTask -TaskPath $e.taskPath -TaskName $e.name | Out-Null }
            }
            'service' {
                if (-not $isAdmin) { throw 'ELEVATION_REQUIRED' }
                if ($e.previousDelayed) { & sc.exe config "$($e.name)" start= delayed-auto | Out-Null }
                else { Set-Service -Name $e.name -StartupType Automatic }
            }
            'powerplan' { powercfg /setactive $e.previousGuid; if ($LASTEXITCODE) { throw "powercfg exit $LASTEXITCODE" } }
            'gamemode' {
                if ($null -eq $e.previous) { Remove-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\GameBar' -Name AutoGameModeEnabled -ErrorAction SilentlyContinue }
                else { Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\GameBar' -Name AutoGameModeEnabled -Value ([int]$e.previous) -Type DWord }
            }
            'appx' {
                $manifest = if ($e.installLocation) { Join-Path $e.installLocation 'AppxManifest.xml' } else { $null }
                if ($manifest -and (Test-Path -LiteralPath $manifest)) { Add-AppxPackage -Register $manifest -DisableDevelopmentMode -ErrorAction Stop }
                else { throw "package files are gone; reinstall '$($e.name)' from the Microsoft Store (search its name) or: winget search `"$($e.name)`" --source msstore" }
            }
            default { throw "unknown kind $($e.kind)" }
        }
        [void](Write-WMJournal @{ kind = 'undo'; undoes = $e.id; name = $e.name; undoable = $false })
        Write-Output "UNDONE: [$($e.id)] $desc"
    } catch {
        Write-Output "UNDO_FAILED: [$($e.id)] $desc - $($_.Exception.Message)"
    }
}
