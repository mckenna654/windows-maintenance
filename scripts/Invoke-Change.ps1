<#
.SYNOPSIS
    Applies one reversible, approved configuration change for the windows-maintenance skill.
.DESCRIPTION
    DRY RUN BY DEFAULT: prints what would change unless -Execute is passed.
    Every executed change is written to %LOCALAPPDATA%\WindowsMaintenance\journal.jsonl with
    the previous state so Undo-Change.ps1 can reverse it.

    Actions
      DisableStartup    -Name <entry> [-Source HKCU-Run|HKLM-Run|HKLM-Run32|User-StartupFolder|Common-StartupFolder|Task]
      EnableStartup     -Name <entry> [-Source ...]
      SetServiceManual  -Name <service>           (Automatic -> Manual only; never Disabled)
      RemoveAppx        -Name <package name>      (current user only; candidates only unless -AllowNonCandidate)
      SetPowerPlan      -Name Balanced|"High performance"|<GUID>
      SetGameMode       -Value On|Off

    Refuses anything matching config\protected.json. The only override is
    -AllowProtectedStartup for startup entries, and only when the user named that entry.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('DisableStartup', 'EnableStartup', 'SetServiceManual', 'RemoveAppx', 'SetPowerPlan', 'SetGameMode')]
    [string]$Action,
    [string]$Name,
    [string]$Source,
    [string]$Value,
    [switch]$Execute,
    [switch]$AllowProtectedStartup,
    [switch]$AllowNonCandidate
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WinMaint.Common.ps1')
$prot = Get-WMProtection
$deb = Get-WMConfig 'debloat-candidates'
$isAdmin = Test-WMAdmin
$mode = if ($Execute) { 'EXECUTE' } else { 'DRY RUN' }

function Out-Result([string]$Status, [string]$Detail, [string]$JournalId = $null) {
    $o = [ordered]@{ action = $Action; name = $Name; status = $Status; detail = $Detail; journalId = $JournalId; mode = $mode }
    Write-Output ("CHANGE_RESULT: " + ($o | ConvertTo-Json -Compress))
    if ($Status -like 'refused*' -or $Status -eq 'error') { exit 1 }
    exit 0
}
function Need-Admin([string]$What) { if (-not $isAdmin) { Out-Result 'skipped-needs-admin' "ELEVATION_REQUIRED: $What" } }

$saBase = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
$startupSources = [ordered]@{
    'HKCU-Run'             = @{ run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; approved = "HKCU:\$saBase\Run"; admin = $false }
    'HKLM-Run'             = @{ run = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; approved = "HKLM:\$saBase\Run"; admin = $true }
    'HKLM-Run32'           = @{ run = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; approved = "HKLM:\$saBase\Run32"; admin = $true }
    'User-StartupFolder'   = @{ folder = [Environment]::GetFolderPath('Startup'); approved = "HKCU:\$saBase\StartupFolder"; admin = $false }
    'Common-StartupFolder' = @{ folder = [Environment]::GetFolderPath('CommonStartup'); approved = "HKLM:\$saBase\StartupFolder"; admin = $true }
}

function Find-StartupEntry([string]$EntryName, [string]$Src) {
    $hits = @()
    foreach ($k in $startupSources.Keys) {
        if ($Src -and $Src -ne $k) { continue }
        $s = $startupSources[$k]
        if ($s.run -and (Test-Path -LiteralPath $s.run)) {
            $key = Get-Item -LiteralPath $s.run
            if ($key.GetValueNames() -contains $EntryName) { $hits += [pscustomobject]@{ source = $k; command = "$($key.GetValue($EntryName))"; approved = $s.approved; admin = $s.admin; kind = 'approved' } }
        }
        if ($s.folder -and (Test-Path -LiteralPath (Join-Path $s.folder $EntryName))) {
            $hits += [pscustomobject]@{ source = $k; command = (Join-Path $s.folder $EntryName); approved = $s.approved; admin = $s.admin; kind = 'approved' }
        }
    }
    if (-not $Src -or $Src -like 'Task*') {
        foreach ($t in @(Get-ScheduledTask -TaskName $EntryName -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notlike '\Microsoft\*' })) {
            $hits += [pscustomobject]@{ source = "Task:$($t.TaskPath)"; command = (@($t.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ; '); taskPath = $t.TaskPath; admin = $true; kind = 'task'; state = "$($t.State)" }
        }
    }
    return ,$hits
}

switch ($Action) {

    { $_ -in 'DisableStartup', 'EnableStartup' } {
        if (-not $Name) { Out-Result 'error' '-Name is required' }
        $hits = Find-StartupEntry $Name $Source
        if ($hits.Count -eq 0) { Out-Result 'error' "no startup entry named '$Name'$(if ($Source) { " in $Source" })" }
        if ($hits.Count -gt 1) { Out-Result 'error' "ambiguous: '$Name' exists in $((@($hits | ForEach-Object source)) -join ', '). Pass -Source." }
        $h = $hits[0]
        if ($Action -eq 'DisableStartup' -and (Test-WMMatchAny "$Name $($h.command)" $prot.protectedStartupPatterns) -and -not $AllowProtectedStartup) {
            Out-Result 'refused-protected' "'$Name' is a protected startup entry (gaming/streaming/security/sync). Only disable it if the user explicitly asked for this entry, using -AllowProtectedStartup."
        }
        if ($h.admin) { Need-Admin "changing $($h.source) startup entries" }
        $enable = ($Action -eq 'EnableStartup')
        if ($h.kind -eq 'task') {
            if (-not $Execute) { Out-Result 'would-change' "$(if ($enable) { 'Enable' } else { 'Disable' }) scheduled task $($h.taskPath)$Name (currently $($h.state))" }
            if ($enable) { Enable-ScheduledTask -TaskPath $h.taskPath -TaskName $Name | Out-Null } else { Disable-ScheduledTask -TaskPath $h.taskPath -TaskName $Name | Out-Null }
            $jid = Write-WMJournal @{ kind = 'startup-task'; action = $Action; name = $Name; taskPath = $h.taskPath; previousState = $h.state; undoable = $true }
            Out-Result 'changed' "$(if ($enable) { 'Enabled' } else { 'Disabled' }) task $($h.taskPath)$Name" $jid
        }
        $prev = $null
        try { $prev = (Get-ItemProperty -LiteralPath $h.approved -Name $Name -ErrorAction Stop).$Name } catch { }
        $prevB64 = if ($prev -is [byte[]]) { [Convert]::ToBase64String($prev) } else { $null }
        $ft = [BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc())
        $bytes = [byte[]](@($(if ($enable) { 2 } else { 3 }), 0, 0, 0) + $(if ($enable) { @(0, 0, 0, 0, 0, 0, 0, 0) } else { $ft }))
        if (-not $Execute) { Out-Result 'would-change' "$(if ($enable) { 'Enable' } else { 'Disable' }) '$Name' ($($h.source)) via StartupApproved, the same reversible switch Task Manager uses. Command: $($h.command)" }
        if (-not (Test-Path -LiteralPath $h.approved)) { New-Item -Path $h.approved -Force | Out-Null }
        Set-ItemProperty -LiteralPath $h.approved -Name $Name -Value $bytes -Type Binary
        $jid = Write-WMJournal @{ kind = 'startup-approved'; action = $Action; name = $Name; source = $h.source; approvedKey = $h.approved; previousBase64 = $prevB64; command = $h.command; undoable = $true }
        Out-Result 'changed' "$(if ($enable) { 'Enabled' } else { 'Disabled' }) '$Name' ($($h.source)). The program itself is untouched." $jid
    }

    'SetServiceManual' {
        if (-not $Name) { Out-Result 'error' '-Name is required' }
        $svc = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f ($Name -replace "'", "''"))
        if (-not $svc) { Out-Result 'error' "service '$Name' not found" }
        if (Test-WMMatchAny $svc.Name $prot.protectedServicePatterns) { Out-Result 'refused-protected' "'$Name' is protected (security, Windows Update/Store, gaming, anti-cheat, GPU or streaming). No override exists." }
        $optional = @($deb.optionalMicrosoftServices | ForEach-Object { $_.name }) -contains $svc.Name
        $isMs = ("$($svc.PathName)" -match '\\Windows\\' -or "$($svc.PathName)" -match 'svchost')
        if ($isMs -and -not $optional) { Out-Result 'refused-protected' "'$Name' is a Windows service that is not on the optional list. This skill only changes Windows services listed in config\debloat-candidates.json." }
        if ($svc.StartMode -ne 'Auto') { Out-Result 'no-change' "'$Name' start mode is already $($svc.StartMode)" }
        Need-Admin "changing service start type for $Name"
        if (-not $Execute) { Out-Result 'would-change' "Set '$($svc.DisplayName)' from Automatic$(if ($svc.DelayedAutoStart) { ' (delayed)' }) to Manual. It can still start on demand." }
        Set-Service -Name $svc.Name -StartupType Manual
        $jid = Write-WMJournal @{ kind = 'service'; action = $Action; name = $svc.Name; displayName = $svc.DisplayName; previousStartMode = $svc.StartMode; previousDelayed = [bool]$svc.DelayedAutoStart; undoable = $true }
        Out-Result 'changed' "'$($svc.DisplayName)' set to Manual (was Automatic). Takes full effect after restart." $jid
    }

    'RemoveAppx' {
        if (-not $Name) { Out-Result 'error' '-Name is required' }
        if (Test-WMMatchAny $Name $prot.protectedAppxPatterns) { Out-Result 'refused-protected' "'$Name' is protected (Store, Xbox/Game Bar/Gaming Services, codecs, runtimes, GPU/audio, security or core shell). No override exists." }
        $pkgs = @(Get-AppxPackage -Name $Name)
        if (-not $pkgs.Count) { Out-Result 'error' "package '$Name' is not installed for this user" }
        if ($pkgs | Where-Object NonRemovable) { Out-Result 'refused-protected' "'$Name' is marked NonRemovable by Windows" }
        $isCandidate = [bool](@($deb.appxCandidates | Where-Object { $Name -match $_.pattern }).Count)
        if (-not $isCandidate -and -not $AllowNonCandidate) { Out-Result 'refused-not-candidate' "'$Name' is not on the debloat candidate list. Pass -AllowNonCandidate only if the user explicitly named it." }
        if (-not $Execute) { Out-Result 'would-change' "Remove $($pkgs.Count) package(s) for the current user: $((@($pkgs | ForEach-Object PackageFullName)) -join ', '). Reinstallable from the Microsoft Store." }
        foreach ($p in $pkgs) {
            Remove-AppxPackage -Package $p.PackageFullName
            $jid = Write-WMJournal @{ kind = 'appx'; action = $Action; name = $p.Name; packageFullName = $p.PackageFullName; installLocation = $p.InstallLocation; packageFamilyName = $p.PackageFamilyName; undoable = $true }
        }
        Out-Result 'changed' "Removed '$Name' for the current user." $jid
    }

    'SetPowerPlan' {
        if (-not $Name) { Out-Result 'error' '-Name is required (Balanced, "High performance" or a GUID)' }
        $plans = @(powercfg /list | ForEach-Object { $m = [regex]::Match($_, '([0-9a-fA-F-]{36})\s+\((.+?)\)'); if ($m.Success) { [pscustomobject]@{ guid = $m.Groups[1].Value; name = $m.Groups[2].Value.Trim(); active = ($_ -match '\*\s*$') } } })
        $target = @($plans | Where-Object { $_.guid -eq $Name -or $_.name -eq $Name })
        if ($target.Count -ne 1) { Out-Result 'error' "power plan '$Name' not found or ambiguous. Available: $((@($plans | ForEach-Object { "$($_.name) ($($_.guid))" })) -join '; ')" }
        $current = @($plans | Where-Object active)[0]
        if ($current.guid -eq $target[0].guid) { Out-Result 'no-change' "'$($target[0].name)' is already active" }
        if (-not $Execute) { Out-Result 'would-change' "Switch power plan from '$($current.name)' to '$($target[0].name)'" }
        powercfg /setactive $target[0].guid
        if ($LASTEXITCODE -ne 0) { Out-Result 'error' "powercfg exit $LASTEXITCODE" }
        $jid = Write-WMJournal @{ kind = 'powerplan'; action = $Action; name = $target[0].name; guid = $target[0].guid; previousGuid = $current.guid; previousName = $current.name; undoable = $true }
        Out-Result 'changed' "Power plan '$($current.name)' -> '$($target[0].name)'" $jid
    }

    'SetGameMode' {
        if ($Value -notin 'On', 'Off') { Out-Result 'error' '-Value On|Off is required' }
        $key = 'HKCU:\Software\Microsoft\GameBar'
        $prev = $null; try { $prev = (Get-ItemProperty -LiteralPath $key -Name AutoGameModeEnabled -ErrorAction Stop).AutoGameModeEnabled } catch { }
        if (-not $Execute) { Out-Result 'would-change' "Set Game Mode $Value (the Settings > Gaming > Game Mode toggle). Previous: $(if ($null -eq $prev) { 'default (On)' } else { $prev })" }
        if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
        Set-ItemProperty -LiteralPath $key -Name AutoGameModeEnabled -Value $(if ($Value -eq 'On') { 1 } else { 0 }) -Type DWord
        $jid = Write-WMJournal @{ kind = 'gamemode'; action = $Action; value = $Value; previous = $prev; undoable = $true }
        Out-Result 'changed' "Game Mode $Value" $jid
    }
}
