<#
.SYNOPSIS
    Read-only Windows 11 maintenance audit for the windows-maintenance skill.
.DESCRIPTION
    Collects system, storage, cleanup estimates, startup, services, apps, performance,
    gaming, driver, health, security and developer-environment data. It makes NO
    changes: it only reads, apart from writing its own report files to
    %LOCALAPPDATA%\WindowsMaintenance\reports.
.PARAMETER Mode
    Audit (default, all standard sections) | Clean | Debloat | Optimise | Deep.
.PARAMETER Label
    Free-text tag stored in the snapshot and file name, e.g. "before" or "after".
.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File Invoke-Audit.ps1 -Mode Audit -Label before
#>
[CmdletBinding()]
param(
    [ValidateSet('Audit', 'Clean', 'Debloat', 'Optimise', 'Optimize', 'Deep')]
    [string]$Mode = 'Audit',
    [string]$Label = '',
    [string[]]$DevRoots = @(),
    [ValidateRange(1, 15)][int]$SampleSeconds = 3,
    [switch]$IncludeWinget,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'WinMaint.Common.ps1')
if ($Mode -eq 'Optimize') { $Mode = 'Optimise' }

$sectionsByMode = @{
    Audit    = @('system', 'storage', 'cleanup', 'startup', 'services', 'apps', 'performance', 'gaming', 'drivers', 'health', 'security', 'dev')
    Deep     = @('system', 'storage', 'cleanup', 'startup', 'services', 'apps', 'performance', 'gaming', 'drivers', 'health', 'security', 'dev', 'deep')
    Clean    = @('system', 'storage', 'cleanup', 'dev')
    Debloat  = @('system', 'startup', 'services', 'apps', 'performance')
    Optimise = @('system', 'storage', 'performance', 'gaming', 'drivers', 'health', 'security')
}
$sections = $sectionsByMode[$Mode]
$isAdmin = Test-WMAdmin
$started = Get-Date
$findings = New-Object System.Collections.Generic.List[object]
$audit = [ordered]@{
    schemaVersion = 1
    tool          = 'windows-maintenance'
    mode          = $Mode
    label         = $Label
    startedAt     = $started.ToString('o')
    elevated      = $isAdmin
    psVersion     = $PSVersionTable.PSVersion.ToString()
    sections      = $sections
    errors        = @()
}

function Add-Finding([string]$Severity, [string]$Area, [string]$Title, [string]$Detail, [string]$Recommendation) {
    $findings.Add([pscustomobject]@{ severity = $Severity; area = $Area; title = $Title; detail = $Detail; recommendation = $Recommendation })
}
function Invoke-Section([string]$Name, [scriptblock]$Body) {
    if ($sections -notcontains $Name) { return }
    if (-not $Quiet) { Write-Host "  - $Name" -ForegroundColor DarkGray }
    try { $audit[$Name] = & $Body }
    catch { $audit.errors += "$Name : $($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber): $("$($_.InvocationInfo.Line)".Trim())"; $audit[$Name] = $null }
}
function Get-RegValue([string]$Path, [string]$Name) {
    try { return (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}
function Get-EventCount([hashtable]$Filter, [int]$Max = 500) {
    try { return @(Get-WinEvent -FilterHashtable $Filter -MaxEvents $Max -ErrorAction Stop) } catch { return @() }
}

if (-not $Quiet) { Write-Host "windows-maintenance audit ($Mode, read-only)$(if ($isAdmin) { ' [elevated]' } else { ' [standard user]' })" -ForegroundColor Cyan }

# ============================================================ system
Invoke-Section 'system' {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = @(Get-CimInstance Win32_Processor)[0]
    $bb = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue
    $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
    $nt = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $uptime = (Get-Date) - $os.LastBootUpTime
    [ordered]@{
        computerName  = $env:COMPUTERNAME
        os            = $os.Caption
        displayVersion= Get-RegValue $nt 'DisplayVersion'
        build         = "$($os.BuildNumber).$(Get-RegValue $nt 'UBR')"
        installDate   = $os.InstallDate.ToString('yyyy-MM-dd')
        lastBoot      = $os.LastBootUpTime.ToString('o')
        uptimeDays    = [math]::Round($uptime.TotalDays, 1)
        manufacturer  = $cs.Manufacturer
        model         = $cs.Model
        isLaptop      = ($cs.PCSystemType -eq 2)
        motherboard   = if ($bb) { "$($bb.Manufacturer) $($bb.Product)" } else { $null }
        bios          = if ($bios) { "$($bios.SMBIOSBIOSVersion) ($(if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString('yyyy-MM-dd') }))" } else { $null }
        cpu           = $cpu.Name.Trim()
        cores         = $cpu.NumberOfCores
        threads       = $cpu.NumberOfLogicalProcessors
        ramGB         = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    }
}

# ============================================================ storage
Invoke-Section 'storage' {
    $partMap = @{}
    try { foreach ($p in Get-Partition -ErrorAction Stop | Where-Object DriveLetter) { $partMap["$($p.DriveLetter):"] = $p.DiskNumber } } catch { }
    $phys = @()
    try { $phys = @(Get-PhysicalDisk -ErrorAction Stop) } catch { }
    $physByNum = @{}
    foreach ($d in $phys) { $physByNum["$($d.DeviceId)"] = $d }

    $volumes = foreach ($ld in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3') {
        $pct = if ($ld.Size) { [math]::Round($ld.FreeSpace / $ld.Size * 100, 1) } else { 0 }
        $disk = $null
        if ($partMap.ContainsKey($ld.DeviceID)) { $disk = $physByNum["$($partMap[$ld.DeviceID])"] }
        if ($pct -lt 10) { Add-Finding 'high' 'storage' "Drive $($ld.DeviceID) is $([math]::Round(100-$pct))% full" "$(Format-WMBytes $ld.FreeSpace) free of $(Format-WMBytes $ld.Size)." 'Run Clean mode; move large game libraries or projects to a drive with more space.' }
        elseif ($pct -lt 15) { Add-Finding 'medium' 'storage' "Drive $($ld.DeviceID) has under 15% free" "$(Format-WMBytes $ld.FreeSpace) free." 'Run Clean mode to recover space.' }
        [ordered]@{
            drive = $ld.DeviceID; label = $ld.VolumeName; fileSystem = $ld.FileSystem
            sizeBytes = [int64]$ld.Size; freeBytes = [int64]$ld.FreeSpace; freePct = $pct
            disk = if ($disk) { $disk.FriendlyName } else { $null }
            mediaType = if ($disk) { "$($disk.MediaType)" } else { $null }
            busType = if ($disk) { "$($disk.BusType)" } else { $null }
        }
    }

    $disks = foreach ($d in $phys) {
        $rel = $null
        if ($isAdmin) { try { $rel = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { } }
        if ("$($d.HealthStatus)" -ne 'Healthy') { Add-Finding 'high' 'storage' "Disk '$($d.FriendlyName)' health is $($d.HealthStatus)" "Operational status: $($d.OperationalStatus)." 'Back up important data now and check the drive with the manufacturer tool.' }
        if ($rel -and $rel.Wear -ge 80) { Add-Finding 'medium' 'storage' "SSD '$($d.FriendlyName)' wear at $($rel.Wear)%" 'Wear indicator from storage reliability counters.' 'Plan a replacement and keep backups current.' }
        [ordered]@{
            name = $d.FriendlyName; mediaType = "$($d.MediaType)"; busType = "$($d.BusType)"; sizeBytes = [int64]$d.Size
            health = "$($d.HealthStatus)"; operational = "$($d.OperationalStatus -join ',')"
            temperatureC = if ($rel) { $rel.Temperature } else { $null }
            wearPct = if ($rel) { $rel.Wear } else { $null }
            readErrorsUncorrected = if ($rel) { $rel.ReadErrorsUncorrected } else { $null }
            powerOnHours = if ($rel) { $rel.PowerOnHours } else { $null }
        }
    }

    $trim = $null
    try {
        $t = (fsutil behavior query DisableDeleteNotify 2>$null | Out-String)
        if ($t -match 'NTFS DisableDeleteNotify\s*=\s*(\d)') { $trim = ($Matches[1] -eq '0') }
    } catch { }
    if ($trim -eq $false) { Add-Finding 'medium' 'storage' 'TRIM is disabled for NTFS' 'fsutil reports DisableDeleteNotify = 1.' 'Re-enable with: fsutil behavior set DisableDeleteNotify 0 (admin). Supported Microsoft setting.' }

    [ordered]@{ volumes = @($volumes); physicalDisks = @($disks); trimEnabled = $trim; reliabilityCountersNeedAdmin = (-not $isAdmin) }
}

# ============================================================ cleanup estimates
Invoke-Section 'cleanup' {
    $catalog = Get-WMConfig 'clean-targets'
    $results = foreach ($t in $catalog.targets) {
        $pathsSpec = @()
        if ($t.paths) { $pathsSpec += $t.paths }
        if ($t.measurePaths) { $pathsSpec += $t.measurePaths }
        $script:WM_Inaccessible.Clear()
        $resolved = Resolve-WMPaths $pathsSpec
        $inaccessible = $script:WM_Inaccessible.Count
        $minAge = if ($null -ne $t.minAgeDays) { [int]$t.minAgeDays } else { 0 }
        $total = [int64]0; $eligible = [int64]0; $files = [int64]0; $errors = 0; $trunc = $false
        foreach ($p in $resolved) {
            $m = Measure-WMPath $p $minAge 15
            $total += $m.TotalBytes; $eligible += $m.EligibleBytes; $files += $m.FileCount; $errors += $m.Errors
            if ($m.Truncated) { $trunc = $true }
        }
        if ($t.method -eq 'recycle-bin') {
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            foreach ($d in [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }) {
                $rb = Join-Path $d.RootDirectory.FullName "`$Recycle.Bin\$sid"
                if (Test-Path -LiteralPath $rb) { $m = Measure-WMPath $rb 0 15; $total += $m.TotalBytes; $eligible += $m.TotalBytes; $files += $m.FileCount; $resolved += $rb }
            }
        }
        $tool = $null
        if ($t.method -eq 'tool-command') { $c = Get-Command $t.command.exe -ErrorAction SilentlyContinue; $tool = [bool]$c }
        $running = @()
        if ($t.requiresClosed) { $running = Get-WMRunningProcesses ([string[]]$t.requiresClosed) }
        $needsAdminToMeasure = (-not $isAdmin -and ($errors -gt 0 -or $inaccessible -gt 0))
        [ordered]@{
            id = $t.id; label = $t.label; category = $t.category; tier = [int]$t.tier; scope = $t.scope; method = $t.method
            minAgeDays = $minAge; paths = @($resolved); totalBytes = $total; estimatedRecoverableBytes = $(if ($t.method -eq 'report-only') { 0 } else { $eligible })
            fileCount = $files; accessErrors = $errors; truncated = $trunc; measurementIncomplete = ($needsAdminToMeasure -or $trunc)
            toolAvailable = $tool; blockingProcesses = @($running); note = $t.note
        }
    }
    $results = @($results)
    $sum = { param($tier) $s = [int64]0; foreach ($r in $results) { if ($r.tier -eq $tier -and $r.method -ne 'report-only') { $s += [int64]$r.estimatedRecoverableBytes } }; $s }
    $t1 = & $sum 1; $t2 = & $sum 2; $t3 = & $sum 3
    if ($t1 -gt 2GB) { Add-Finding 'low' 'cleanup' "About $(Format-WMBytes $t1) of low-risk temporary data" 'Temp files, caches, logs and error reports that regenerate.' 'Run Clean mode (tier 1).' }
    $rb = $results | Where-Object { $_.id -eq 'recycle-bin' }
    if ($rb -and $rb.totalBytes -gt 5GB) { Add-Finding 'low' 'cleanup' "Recycle Bin holds $(Format-WMBytes $rb.totalBytes)" 'These are your deleted files.' 'Review and empty it yourself, or approve it explicitly in Clean mode.' }
    [ordered]@{
        targets = $results
        estimatedTier1Bytes = $t1; estimatedTier2Bytes = $t2; reviewOnlyTier3Bytes = $t3
        note = 'Estimates are logical file sizes of files that pass the age filter and exclusions. Locked/in-use files are skipped at clean time, so actual recovery is usually lower.'
    }
}

# ============================================================ startup
Invoke-Section 'startup' {
    $prot = Get-WMProtection
    $deb = Get-WMConfig 'debloat-candidates'
    $saBase = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    $sources = @(
        @{ hive = 'HKCU'; key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; approved = "HKCU:\$saBase\Run"; source = 'HKCU-Run' },
        @{ hive = 'HKLM'; key = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; approved = "HKLM:\$saBase\Run"; source = 'HKLM-Run' },
        @{ hive = 'HKLM'; key = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; approved = "HKLM:\$saBase\Run32"; source = 'HKLM-Run32' }
    )
    $classify = {
        param($name, $cmd)
        $hay = "$name $cmd"
        if (Test-WMMatchAny $hay $prot.protectedStartupPatterns) { return @('protected', $null) }
        foreach ($o in $deb.optionalStartupPatterns) { if ($hay -match $o.pattern) { return @('candidate', $o.label + $(if ($o.note) { " - $($o.note)" } else { '' })) } }
        return @('review', $null)
    }
    $isEnabled = {
        param($approvedKey, $name)
        # Read via the key object: returning a byte[] through a function unrolls it into object[].
        $v = $null
        try { $k = Get-Item -LiteralPath $approvedKey -ErrorAction Stop; $v = $k.GetValue($name) } catch { }
        if ($v -is [byte[]] -and $v.Length -gt 0) { return (($v[0] -band 1) -eq 0) }
        return $true
    }
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($s in $sources) {
        if (-not (Test-Path -LiteralPath $s.key)) { continue }
        $k = Get-Item -LiteralPath $s.key
        foreach ($n in $k.GetValueNames()) {
            if (-not $n) { continue }
            $cmd = "$($k.GetValue($n))"
            $c = & $classify $n $cmd
            $items.Add([ordered]@{ name = $n; source = $s.source; command = $cmd; enabled = (& $isEnabled $s.approved $n); class = $c[0]; reason = $c[1]; needsAdmin = ($s.hive -eq 'HKLM') })
        }
    }
    $folders = @(
        @{ path = [Environment]::GetFolderPath('Startup'); approved = "HKCU:\$saBase\StartupFolder"; source = 'User-StartupFolder'; admin = $false },
        @{ path = [Environment]::GetFolderPath('CommonStartup'); approved = "HKLM:\$saBase\StartupFolder"; source = 'Common-StartupFolder'; admin = $true }
    )
    foreach ($f in $folders) {
        if (-not (Test-Path -LiteralPath $f.path)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $f.path -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' }) {
            $c = & $classify $file.Name $file.FullName
            $items.Add([ordered]@{ name = $file.Name; source = $f.source; command = $file.FullName; enabled = (& $isEnabled $f.approved $file.Name); class = $c[0]; reason = $c[1]; needsAdmin = $f.admin })
        }
    }
    try {
        foreach ($task in Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -notlike '\Microsoft\*' }) {
            $trig = @($task.Triggers | ForEach-Object { $_.CimClass.CimClassName -replace '^MSFT_Task', '' -replace 'Trigger$', '' })
            if (-not ($trig -contains 'Logon' -or $trig -contains 'Boot')) { continue }
            $cmd = (@($task.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)".Trim() }) -join ' ; ')
            $c = & $classify $task.TaskName $cmd
            $items.Add([ordered]@{ name = $task.TaskName; source = "Task:$($task.TaskPath)"; command = $cmd; enabled = ("$($task.State)" -ne 'Disabled'); class = $c[0]; reason = $c[1]; needsAdmin = $true; triggers = ($trig -join ',') })
        }
    } catch { }
    $all = $items.ToArray()
    $enabled = @($all | Where-Object { $_.enabled })
    $cands = @($enabled | Where-Object { $_.class -eq 'candidate' })
    if ($enabled.Count -ge 15) { Add-Finding 'medium' 'startup' "$($enabled.Count) programs start at sign-in" "$($cands.Count) look optional." 'Review the candidates in Debloat mode; disabling is reversible.' }
    elseif ($cands.Count -gt 0) { Add-Finding 'low' 'startup' "$($cands.Count) optional startup item(s)" (($cands | ForEach-Object { $_.name }) -join ', ') 'Review in Debloat mode; disabling is reversible.' }
    [ordered]@{ items = $all; enabledCount = $enabled.Count; candidateCount = $cands.Count }
}

# ============================================================ services
Invoke-Section 'services' {
    $prot = Get-WMProtection
    $deb = Get-WMConfig 'debloat-candidates'
    $optMs = @{}; foreach ($o in $deb.optionalMicrosoftServices) { $optMs[$o.name] = $o }
    $svcs = @(Get-CimInstance Win32_Service)
    $list = foreach ($s in $svcs) {
        $path = "$($s.PathName)"
        $isMs = ($path -match '\\Windows\\' -or $path -match 'Microsoft' -or $path -match 'svchost')
        $class = 'other'
        if (Test-WMMatchAny $s.Name $prot.protectedServicePatterns) { $class = 'protected' }
        elseif ($optMs.ContainsKey($s.Name)) { $class = 'optional-microsoft' }
        elseif (-not $isMs -and $s.StartMode -eq 'Auto') { $class = 'third-party-auto' }
        if ($class -eq 'other') { continue }
        [ordered]@{
            name = $s.Name; displayName = $s.DisplayName; startMode = $s.StartMode; delayed = [bool]$s.DelayedAutoStart
            state = $s.State; class = $class; path = $path
            note = if ($optMs.ContainsKey($s.Name)) { $optMs[$s.Name].note } else { $null }
        }
    }
    $list = @($list)
    $third = @($list | Where-Object { $_.class -eq 'third-party-auto' })
    $optOn = @($list | Where-Object { $_.class -eq 'optional-microsoft' -and $_.startMode -eq 'Auto' })
    if ($third.Count -gt 0) { Add-Finding 'info' 'services' "$($third.Count) third-party service(s) start automatically" (($third | ForEach-Object { $_.displayName }) -join '; ') 'Review in Debloat mode. Only switch to Manual (never Disabled) and only for software you recognise and do not need at boot.' }
    [ordered]@{
        totalServices = $svcs.Count
        autoStartCount = @($svcs | Where-Object StartMode -eq 'Auto').Count
        runningCount = @($svcs | Where-Object State -eq 'Running').Count
        items = $list
        optionalMicrosoftAuto = $optOn.Count
    }
}

# ============================================================ apps
Invoke-Section 'apps' {
    $prot = Get-WMProtection
    $deb = Get-WMConfig 'debloat-candidates'
    $appx = @()
    try { $appx = @(Get-AppxPackage -ErrorAction Stop | Where-Object { -not $_.IsFramework }) } catch { }
    $appxCands = foreach ($a in $appx) {
        if (Test-WMMatchAny $a.Name $prot.protectedAppxPatterns) { continue }
        if ($a.NonRemovable) { continue }
        foreach ($c in $deb.appxCandidates) {
            if ($a.Name -match $c.pattern) {
                [ordered]@{ name = $a.Name; label = $c.label; version = "$($a.Version)"; note = $c.note; signatureKind = "$($a.SignatureKind)" }
                break
            }
        }
    }
    $appxCands = @($appxCands)

    $keys = @('HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $seen = @{}
    $programs = foreach ($k in $keys) {
        foreach ($p in Get-ItemProperty -Path $k -ErrorAction SilentlyContinue) {
            if (-not $p.DisplayName -or $p.SystemComponent -eq 1 -or $p.ParentKeyName) { continue }
            if ($seen.ContainsKey($p.DisplayName)) { continue }
            $seen[$p.DisplayName] = 1
            [ordered]@{ name = $p.DisplayName; publisher = $p.Publisher; version = $p.DisplayVersion; installDate = $p.InstallDate
                        sizeMB = if ($p.EstimatedSize) { [math]::Round($p.EstimatedSize / 1024, 0) } else { $null } }
        }
    }
    $programs = @($programs | Sort-Object { $_.name })
    $suspects = foreach ($p in $programs) {
        foreach ($s in $deb.suspectProgramPatterns) {
            if ($p.name -match $s.pattern) { [ordered]@{ name = $p.name; label = $s.label; note = $s.note }; break }
        }
    }
    $suspects = @($suspects)
    if ($appxCands.Count -gt 0) { Add-Finding 'low' 'apps' "$($appxCands.Count) preinstalled Store app(s) look removable" (($appxCands | ForEach-Object { $_.label } | Select-Object -Unique) -join ', ') 'Review in Debloat mode; removal is per-user and reinstallable from the Microsoft Store.' }
    foreach ($s in $suspects) { Add-Finding 'medium' 'apps' "$($s.name) installed" "$($s.label). $($s.note)" 'Consider uninstalling via Settings > Apps > Installed apps.' }
    [ordered]@{
        appxInstalledCount = $appx.Count
        appxCandidates = $appxCands
        win32ProgramCount = $programs.Count
        largestPrograms = @($programs | Where-Object { $_.sizeMB } | Sort-Object { [double]$_.sizeMB } -Descending | Select-Object -First 15)
        suspectPrograms = $suspects
        programs = $programs
    }
}

# ============================================================ performance
Invoke-Section 'performance' {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $lp = [int]$cs.NumberOfLogicalProcessors
    $t0 = @{}; foreach ($p in Get-Process) { try { $t0[$p.Id] = $p.TotalProcessorTime.TotalMilliseconds } catch { } }
    Start-Sleep -Seconds $SampleSeconds
    $procs = @(Get-Process)
    $cpuRows = foreach ($p in $procs) {
        if (-not $t0.ContainsKey($p.Id)) { continue }
        try { $d = $p.TotalProcessorTime.TotalMilliseconds - $t0[$p.Id] } catch { continue }
        [pscustomobject]@{ name = $p.ProcessName; pid = $p.Id; cpuPct = [math]::Round($d / ($SampleSeconds * 1000 * $lp) * 100, 1) }
    }
    $topCpu = @($cpuRows | Group-Object name | ForEach-Object { [ordered]@{ name = $_.Name; cpuPct = [math]::Round(($_.Group | Measure-Object cpuPct -Sum).Sum, 1); processes = $_.Count } } | Sort-Object { $_.cpuPct } -Descending | Select-Object -First 10)
    $topMem = @($procs | Group-Object ProcessName | ForEach-Object { [ordered]@{ name = $_.Name; workingSetMB = [math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB, 0); processes = $_.Count } } | Sort-Object { $_.workingSetMB } -Descending | Select-Object -First 10)
    $totalMB = [math]::Round($os.TotalVisibleMemorySize / 1KB, 0); $freeMB = [math]::Round($os.FreePhysicalMemory / 1KB, 0)
    $usedPct = [math]::Round(($totalMB - $freeMB) / $totalMB * 100, 1)
    $commitTotal = [math]::Round($os.TotalVirtualMemorySize / 1KB, 0); $commitFree = [math]::Round($os.FreeVirtualMemory / 1KB, 0)
    $pf = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
    if ($usedPct -gt 85) { Add-Finding 'medium' 'performance' "Memory use is $usedPct% at idle-time sampling" "Top: $((@($topMem | Select-Object -First 3 | ForEach-Object { "$($_.name) $($_.workingSetMB) MB" })) -join ', ')" 'Close or remove heavy background apps; check the startup list.' }
    $busy = @($topCpu | Where-Object { $_.cpuPct -ge 10 -and $_.name -notin @('Idle', 'pwsh', 'powershell', 'System') })
    foreach ($b in $busy) { Add-Finding 'low' 'performance' "$($b.name) used $($b.cpuPct)% CPU during the sample" "Sampled over $SampleSeconds s across $lp logical processors." 'Check whether this is expected background work.' }
    if (-not $cs.AutomaticManagedPagefile) { Add-Finding 'low' 'performance' 'Page file is manually sized' (($pf | ForEach-Object { "$($_.Name) $($_.AllocatedBaseSize) MB" }) -join '; ') 'System-managed is the safe default for gaming and compiling; only change if you have a specific reason.' }
    [ordered]@{
        sampleSeconds = $SampleSeconds; processCount = $procs.Count
        memory = [ordered]@{ totalMB = $totalMB; availableMB = $freeMB; usedPct = $usedPct; commitLimitMB = $commitTotal; commitAvailableMB = $commitFree }
        pagefile = [ordered]@{ systemManaged = [bool]$cs.AutomaticManagedPagefile; files = @($pf | ForEach-Object { [ordered]@{ path = $_.Name; allocatedMB = $_.AllocatedBaseSize; currentMB = $_.CurrentUsage; peakMB = $_.PeakUsage } }) }
        topCpu = $topCpu; topMemory = $topMem
    }
}

# ============================================================ gaming
Invoke-Section 'gaming' {
    $out = [ordered]@{}
    # power plan
    $active = (powercfg /getactivescheme 2>$null | Out-String)
    $m = [regex]::Match($active, '([0-9a-fA-F-]{36})\s+\((.+)\)')
    $plans = @(powercfg /list 2>$null | ForEach-Object { $mm = [regex]::Match($_, '([0-9a-fA-F-]{36})\s+\((.+?)\)'); if ($mm.Success) { [ordered]@{ guid = $mm.Groups[1].Value; name = $mm.Groups[2].Value; active = ($_ -match '\*\s*$') } } })
    $out.powerPlan = [ordered]@{ activeGuid = $m.Groups[1].Value; activeName = $m.Groups[2].Value; available = $plans }

    # Windows gaming settings (all Settings-app backed)
    $gm = Get-RegValue 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled'
    $out.gameMode = if ($null -eq $gm) { 'On (default)' } elseif ($gm -eq 1) { 'On' } else { 'Off' }
    $appCap = Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled'
    $hist = Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'HistoricalCaptureEnabled'
    $out.gameCapture = [ordered]@{ captureEnabled = $appCap; backgroundRecording = ($hist -eq 1) }
    $hags = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
    $out.hardwareGpuScheduling = switch ($hags) { 2 { 'On' } 1 { 'Off' } default { 'Not set (driver default)' } }
    $dx = "$(Get-RegValue 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' 'DirectXUserGlobalSettings')"
    $out.windowedGameOptimizations = if ($dx -match 'SwapEffectUpgradeEnable=1') { 'On' } elseif ($dx -match 'SwapEffectUpgradeEnable=0') { 'Off' } else { 'Default' }
    $out.variableRefreshRate = if ($dx -match 'VRROptimizeEnable=1') { 'On' } elseif ($dx -match 'VRROptimizeEnable=0') { 'Off' } else { 'Default' }

    # VBS / HVCI (security feature: reported only, never changed by this skill)
    try {
        $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop
        $out.vbs = [ordered]@{ vbsStatus = switch ($dg.VirtualizationBasedSecurityStatus) { 0 { 'Off' } 1 { 'Enabled, not running' } 2 { 'Running' } default { "$_" } }
                                memoryIntegrityRunning = (@($dg.SecurityServicesRunning) -contains 2) }
    } catch { $out.vbs = $null }

    # display + GPU
    $vcs = @(Get-CimInstance Win32_VideoController)
    $out.gpus = @(foreach ($v in $vcs) {
        $age = if ($v.DriverDate) { [math]::Round(((Get-Date) - $v.DriverDate).TotalDays) } else { $null }
        if ($v.CurrentRefreshRate -and $v.MaxRefreshRate -and $v.CurrentRefreshRate -le 60 -and $v.MaxRefreshRate -ge 100) {
            Add-Finding 'medium' 'gaming' "$($v.Name): display at $($v.CurrentRefreshRate) Hz, panel reports up to $($v.MaxRefreshRate) Hz" 'A high-refresh monitor running at 60 Hz is the most common free gaming win.' 'Settings > System > Display > Advanced display > Choose a refresh rate (and use DisplayPort/HDMI 2.1 cable).'
        }
        [ordered]@{ name = $v.Name; driverVersion = $v.DriverVersion; driverDate = if ($v.DriverDate) { $v.DriverDate.ToString('yyyy-MM-dd') } else { $null }; driverAgeDays = $age
                    resolution = "$($v.CurrentHorizontalResolution)x$($v.CurrentVerticalResolution)"; refreshHz = $v.CurrentRefreshRate; maxRefreshHz = $v.MaxRefreshRate; status = $v.Status }
    })

    # RAM configuration
    $sticks = @(Get-CimInstance Win32_PhysicalMemory)
    $out.memoryModules = @($sticks | ForEach-Object { [ordered]@{ slot = "$($_.BankLabel) $($_.DeviceLocator)".Trim(); sizeGB = [math]::Round($_.Capacity / 1GB); ratedMTs = $_.Speed; configuredMTs = $_.ConfiguredClockSpeed; manufacturer = "$($_.Manufacturer)".Trim(); partNumber = "$($_.PartNumber)".Trim(); type = switch ($_.SMBIOSMemoryType) { 34 { 'DDR5' } 26 { 'DDR4' } 24 { 'DDR3' } default { "$_" } } } })
    if ($sticks.Count -eq 1) { Add-Finding 'medium' 'gaming' 'Single memory module (single-channel)' "$([math]::Round($sticks[0].Capacity/1GB)) GB in $($sticks[0].DeviceLocator)." 'A matched pair runs dual-channel, a measurable uplift in CPU-bound games. Hardware change - your call.' }
    $slow = @($sticks | Where-Object { $_.ConfiguredClockSpeed -and $_.Speed -and $_.ConfiguredClockSpeed -lt ($_.Speed * 0.9) })
    if ($slow.Count) { Add-Finding 'medium' 'gaming' "RAM configured at $($slow[0].ConfiguredClockSpeed) MT/s, below its reported $($slow[0].Speed) MT/s" 'Memory is running below the speed the module reports.' 'Check BIOS memory settings (EXPO/XMP). This is a firmware setting you change yourself; test stability afterwards.' }
    else {
        $s0 = $sticks | Select-Object -First 1
        if ($s0 -and $s0.SMBIOSMemoryType -eq 34 -and $s0.ConfiguredClockSpeed -le 4800) { Add-Finding 'low' 'gaming' "DDR5 running at $($s0.ConfiguredClockSpeed) MT/s (JEDEC base)" "Part number: $("$($s0.PartNumber)".Trim())." 'If the kit is sold as faster (e.g. DDR5-6000), enable EXPO/XMP in BIOS yourself and test stability.' }
        if ($s0 -and $s0.SMBIOSMemoryType -eq 26 -and $s0.ConfiguredClockSpeed -le 2666) { Add-Finding 'low' 'gaming' "DDR4 running at $($s0.ConfiguredClockSpeed) MT/s" "Part number: $("$($s0.PartNumber)".Trim())." 'If the kit is rated faster (e.g. 3200/3600), enable XMP/DOCP in BIOS yourself.' }
    }

    # software detection
    $svcNames = @(Get-Service -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $drvNames = @(Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $progNames = @()
    foreach ($k in 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*') {
        $progNames += @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue | Where-Object DisplayName | ForEach-Object { $_.DisplayName })
    }
    $appxNames = @(); try { $appxNames = @(Get-AppxPackage -ErrorAction Stop | ForEach-Object { $_.Name }) } catch { }
    $has = { param($list, $pattern) [bool](@($list | Where-Object { $_ -match $pattern }).Count) }
    $out.software = [ordered]@{
        steam = [bool](Get-WMSteamPath)
        xboxApp = & $has $appxNames '^Microsoft\.GamingApp$'
        gameBar = & $has $appxNames '^Microsoft\.XboxGamingOverlay$'
        gamingServices = & $has $svcNames '^GamingServices$'
        epic = & $has $progNames 'Epic Games Launcher'
        eaApp = & $has $progNames '^EA app$|EA Desktop'
        battleNet = & $has $progNames 'Battle\.net'
        ubisoft = & $has $progNames 'Ubisoft Connect'
        gog = & $has $progNames 'GOG GALAXY'
        amdAdrenalin = (& $has $progNames '^AMD Software') -or (& $has $appxNames 'AMDRadeonSoftware')
        amdChipset = & $has $progNames 'AMD Chipset Software'
        amd3dVCacheOptimizer = & $has $svcNames '^amd3dvcacheSvc$'
        moonlight = & $has $progNames 'Moonlight'
        sunshine = (& $has $svcNames '^SunshineService$|^sunshinesvc$') -or (& $has $progNames '^Sunshine')
        apollo = (& $has $svcNames '^ApolloService$') -or (& $has $progNames '^Apollo')
        parsec = & $has $progNames 'Parsec'
        obs = & $has $progNames 'OBS Studio'
        discord = & $has $progNames '^Discord'
        tailscale = & $has $svcNames '^Tailscale$'
    }
    $acPatterns = @('^EasyAntiCheat', '^BEService$', '^BEDaisy$', '^vgc$', '^vgk$', '^FACEIT', '^EAAntiCheat', '^PnkBstr', '^ESEADriver', '^npggsvc$', '^xhunter', '^mhyprot', '^Denuvo')
    $out.antiCheat = @(($svcNames + $drvNames) | Where-Object { Test-WMMatchAny $_ $acPatterns } | Select-Object -Unique)

    $cpuName = "$($audit.system.cpu)"
    $out.dualCcdX3D = ($cpuName -match '\b(7900X3D|7950X3D|9900X3D|9950X3D)\b')
    $out.software.virtualDisplayDriver = [bool](@($vcs | Where-Object { $_.Name -match 'Virtual Display|IddSample|Mtt|Parsec|SudoMaker|Sunshine' }).Count)
    if ($out.dualCcdX3D) {
        if ($out.gameMode -eq 'Off') { Add-Finding 'high' 'gaming' 'Game Mode is off on a dual-CCD Ryzen X3D CPU' 'AMD 3D V-Cache Performance Optimizer relies on Game Mode + Game Bar to park the non-V-Cache CCD during games.' 'Turn Game Mode on: Settings > Gaming > Game Mode.' }
        if (-not $out.software.gameBar) { Add-Finding 'high' 'gaming' 'Xbox Game Bar is missing on a dual-CCD Ryzen X3D CPU' 'AMD core parking uses Game Bar to detect games.' 'Reinstall "Xbox Game Bar" from the Microsoft Store.' }
        if (-not $out.software.amd3dVCacheOptimizer) { Add-Finding 'high' 'gaming' 'AMD 3D V-Cache Performance Optimizer service not found' 'Required for correct core parking on dual-CCD X3D CPUs.' 'Install the latest AMD Chipset Software from amd.com.' }
    }
    # power plan: AMD and Microsoft ship Balanced as the default for Ryzen desktops (CPPC preferred cores, boost, core parking)
    $stdPlans = @('381b4222-f694-41f0-9685-ff5bb260df2e', '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c', 'a1841308-3541-4fab-bc81-f71556f20b4a', 'e9a42b02-d5df-448d-aa00-03f14749eb61')
    $activeGuid = $out.powerPlan.activeGuid
    $planSev = if ($out.dualCcdX3D) { 'high' } else { 'low' }
    if ($activeGuid -and $activeGuid -ne '381b4222-f694-41f0-9685-ff5bb260df2e' -and $cpuName -match 'Ryzen' -and -not $audit.system.isLaptop) {
        $custom = if ($stdPlans -notcontains $activeGuid) { ' It is a custom plan imported by a third-party tool.' } else { '' }
        Add-Finding $planSev 'gaming' "Active power plan is '$($out.powerPlan.activeName)', not Balanced" "AMD recommends the Windows Balanced plan for Ryzen desktops; High/Ultimate plans mostly raise idle power and temperatures with typically little or no FPS gain, and on dual-CCD X3D CPUs they stop core parking from working.$custom" 'Switch to Balanced (reversible, logged): Invoke-Change.ps1 -Action SetPowerPlan -Name Balanced. Benchmark before/after if you want proof.'
    }
    $dupPlans = @($plans | Group-Object { $_.name } | Where-Object Count -gt 1)
    foreach ($d in $dupPlans) { Add-Finding 'info' 'gaming' "Duplicate power plan '$($d.Name)' ($($d.Count) copies)" 'Usually left behind by tweak tools run more than once.' 'Harmless. Remove spare copies in Control Panel > Power Options only if you want a tidy list.' }
    # monitor wired to the iGPU while a discrete GPU exists
    $dgpu = @($vcs | Where-Object { $_.Name -match 'RX \d|Radeon RX|GeForce|RTX|GTX|Arc A|Arc B' })
    $igpuActive = @($vcs | Where-Object { $_.Name -match '^AMD Radeon\(TM\) Graphics$|Intel\(R\) (UHD|Iris|HD) Graphics|Radeon\(TM\) \d+M' -and $_.CurrentHorizontalResolution })
    if ($dgpu.Count -and $igpuActive.Count) { Add-Finding 'low' 'gaming' 'A display is connected to the motherboard (integrated GPU)' "$($igpuActive[0].Name) is driving $($igpuActive[0].CurrentHorizontalResolution)x$($igpuActive[0].CurrentVerticalResolution) @ $($igpuActive[0].CurrentRefreshRate) Hz." 'Fine for a secondary screen. Make sure the gaming monitor is plugged into the graphics card, and games render on the discrete GPU (Settings > System > Display > Graphics).' }
    if ($out.gameCapture.backgroundRecording) { Add-Finding 'low' 'gaming' 'Background recording ("Record what happened") is on' 'Continuously encodes gameplay in the background.' 'Turn off in Settings > Gaming > Captures if you do not use it (you may already use Adrenalin/OBS for clips).' }
    if ($out.gameMode -eq 'Off' -and -not $out.software.amd3dVCacheOptimizer) { Add-Finding 'low' 'gaming' 'Game Mode is off' 'Microsoft default is on.' 'Settings > Gaming > Game Mode.' }
    if ($out.vbs -and $out.vbs.memoryIntegrityRunning) { Add-Finding 'info' 'security' 'Memory Integrity (HVCI) is on' 'Security feature with a small gaming cost on some systems.' 'Reported for context only. This skill will not disable Windows security features.' }

    # game libraries
    $libs = New-Object System.Collections.Generic.List[object]
    $steam = Get-WMSteamPath
    if ($steam) {
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($mm in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs.Add([ordered]@{ platform = 'Steam'; path = ($mm.Groups[1].Value -replace '\\\\', '\') }) }
        }
    }
    foreach ($d in [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }) {
        $xg = Join-Path $d.RootDirectory.FullName 'XboxGames'
        if (Test-Path -LiteralPath $xg) { $libs.Add([ordered]@{ platform = 'Xbox/Game Pass'; path = $xg }) }
    }
    $epicMan = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
    if (Test-Path -LiteralPath $epicMan) {
        $roots = @{}
        foreach ($f in Get-ChildItem -LiteralPath $epicMan -Filter *.item -ErrorAction SilentlyContinue) {
            try { $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json; if ($j.InstallLocation) { $roots[(Split-Path $j.InstallLocation -Parent)] = 1 } } catch { }
        }
        foreach ($r in $roots.Keys) { $libs.Add([ordered]@{ platform = 'Epic'; path = $r }) }
    }
    $vols = @{}
    if ($audit.storage) { foreach ($v in $audit.storage.volumes) { $vols[$v.drive] = $v } }
    foreach ($l in $libs) {
        $dl = $l.path.Substring(0, 2).ToUpper()
        $l.drive = $dl
        if ($vols.ContainsKey($dl)) { $l.mediaType = $vols[$dl].mediaType; $l.freePct = $vols[$dl].freePct }
        if ($l.mediaType -eq 'HDD') { Add-Finding 'low' 'gaming' "$($l.platform) library on a hard drive ($($l.path))" 'Modern games stream assets constantly; HDDs cause long loads and stutter.' 'Move frequently played games to an SSD using the launcher''s own Move feature.' }
    }
    $out.gameLibraries = $libs.ToArray()

    # network
    try {
        $out.network = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object Status -eq 'Up' | ForEach-Object { [ordered]@{ name = $_.Name; description = $_.InterfaceDescription; linkSpeed = $_.LinkSpeed; media = "$($_.PhysicalMediaType)" } })
        $wired = @($out.network | Where-Object { $_.media -match '802\.3' })
        foreach ($w in $wired) { if ($w.linkSpeed -match '^100 Mbps') { Add-Finding 'medium' 'network' "Ethernet '$($w.name)' linked at 100 Mbps" 'Usually a damaged cable, a Cat5 cable or a bad port.' 'Try another cable/port; expect 1 Gbps or more.' } }
        if (-not $wired.Count -and ($out.software.sunshine -or $out.software.apollo -or $out.software.moonlight)) { Add-Finding 'low' 'network' 'Game streaming over Wi-Fi only' 'Moonlight/Sunshine/Apollo detected with no wired connection.' 'Wired Ethernet on the host gives the biggest streaming quality/latency improvement.' }
    } catch { $out.network = @() }
    $out
}

# ============================================================ drivers & updates
Invoke-Section 'drivers' {
    $out = [ordered]@{}
    $problem = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 })
    $out.problemDevices = @($problem | ForEach-Object { [ordered]@{ name = $_.Name; errorCode = $_.ConfigManagerErrorCode; deviceId = $_.PNPDeviceID } })
    foreach ($p in $problem) { if ($p.ConfigManagerErrorCode -ne 22) { Add-Finding 'medium' 'drivers' "Device problem: $($p.Name)" "Device Manager error code $($p.ConfigManagerErrorCode)." 'Check Device Manager; install the driver from the device/motherboard vendor or Windows Update.' } }
    $out.gpuDrivers = @(Get-CimInstance Win32_VideoController | ForEach-Object { [ordered]@{ name = $_.Name; version = $_.DriverVersion; date = if ($_.DriverDate) { $_.DriverDate.ToString('yyyy-MM-dd') } else { $null } } })
    foreach ($g in Get-CimInstance Win32_VideoController) {
        if ($g.DriverDate -and ((Get-Date) - $g.DriverDate).TotalDays -gt 180 -and $g.Name -notmatch 'Basic|Virtual|Parsec|Idd|Mtt') { Add-Finding 'low' 'drivers' "$($g.Name) driver is $([math]::Round(((Get-Date)-$g.DriverDate).TotalDays)) days old" "Version $($g.DriverVersion)." 'Update through the vendor app (AMD Software: Adrenalin Edition > Check for updates). Avoid third-party driver updaters.' }
    }
    $adrenalin = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '^AMD Software' } | Select-Object -First 1
    $out.amdSoftware = if ($adrenalin) { [ordered]@{ name = $adrenalin.DisplayName; version = $adrenalin.DisplayVersion } } else { $null }
    try {
        $disp = (pnputil /enum-drivers /class Display 2>$null | Out-String)
        $out.displayDriverPackages = ([regex]::Matches($disp, 'Published Name:\s+(oem\d+\.inf)')).Count
        if ($out.displayDriverPackages -gt 3) { Add-Finding 'info' 'drivers' "$($out.displayDriverPackages) display driver packages in the driver store" 'Old GPU driver packages accumulate after updates.' 'Optional manual review only (pnputil). The skill does not remove driver packages automatically.' }
    } catch { }
    $hf = @(Get-CimInstance Win32_QuickFixEngineering -ErrorAction SilentlyContinue | Where-Object InstalledOn | Sort-Object InstalledOn -Descending)
    $out.lastUpdateInstalled = if ($hf.Count) { $hf[0].InstalledOn.ToString('yyyy-MM-dd') } else { $null }
    if ($hf.Count -and ((Get-Date) - $hf[0].InstalledOn).TotalDays -gt 45) { Add-Finding 'medium' 'updates' "No Windows update installed for $([math]::Round(((Get-Date)-$hf[0].InstalledOn).TotalDays)) days" "Last: $($out.lastUpdateInstalled) ($($hf[0].HotFixID))." 'Settings > Windows Update > Check for updates.' }
    if ($IncludeWinget -or $Mode -eq 'Deep') {
        $wg = Get-Command winget -ErrorAction SilentlyContinue
        if ($wg) {
            try { $out.wingetUpgrades = @(& winget upgrade --source winget --disable-interactivity 2>$null | Where-Object { $_ -and $_ -notmatch '^\s*[-\\|/]\s*$' } | Select-Object -Last 60) } catch { $out.wingetUpgrades = @("winget failed: $($_.Exception.Message)") }
        }
    }
    $out
}

# ============================================================ health
Invoke-Section 'health' {
    $since = (Get-Date).AddDays(-14)
    $out = [ordered]@{ windowDays = 14 }
    $pending = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pending += 'Component servicing' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pending += 'Windows Update' }
    if (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations') { $pending += 'Pending file renames' }
    $out.pendingReboot = $pending
    if ($pending.Count) { Add-Finding 'low' 'health' 'A restart is pending' ($pending -join ', ') 'Restart before doing maintenance or benchmarking.' }
    $up = $audit.system.uptimeDays
    if ($up -gt 14) { Add-Finding 'low' 'health' "Up for $up days without a restart" 'Long uptimes accumulate leaks and delay updates.' 'Restart regularly (shut down with Fast Startup does not reset the kernel).' }

    $unexpected = Get-EventCount @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since }
    $bugchecks  = Get-EventCount @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since }
    $whea       = Get-EventCount @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $since }
    $tdr        = Get-EventCount @{ LogName = 'System'; ProviderName = 'Display'; Id = 4101; StartTime = $since }
    $disk       = Get-EventCount @{ LogName = 'System'; ProviderName = @('disk', 'Ntfs', 'stornvme', 'storahci'); Level = @(1, 2, 3); StartTime = $since }
    $appCrash   = Get-EventCount @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = $since } 1000
    $appHang    = Get-EventCount @{ LogName = 'Application'; ProviderName = 'Application Hang'; Id = 1002; StartTime = $since }
    $out.unexpectedShutdowns = $unexpected.Count
    $out.bugChecks = @($bugchecks | ForEach-Object { [ordered]@{ time = $_.TimeCreated.ToString('o'); message = ($_.Message -split "`n")[0] } })
    $out.wheaEvents = $whea.Count
    $out.wheaSamples = @($whea | Select-Object -First 5 | ForEach-Object { [ordered]@{ time = $_.TimeCreated.ToString('o'); id = $_.Id; level = $_.LevelDisplayName } })
    $out.gpuDriverTimeouts = $tdr.Count
    $out.diskEvents = $disk.Count
    $crashGroups = @($appCrash | ForEach-Object { if ($_.Properties.Count) { $_.Properties[0].Value } } | Group-Object | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object { [ordered]@{ app = $_.Name; count = $_.Count } })
    $out.appCrashes = $crashGroups
    $out.appHangs = $appHang.Count
    $topErrors = Get-EventCount @{ LogName = 'System'; Level = @(1, 2); StartTime = $since } 2000
    $out.topSystemErrors = @($topErrors | Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object { [ordered]@{ source = $_.Name; count = $_.Count; lastMessage = (($_.Group[0].Message -split "`n")[0]) } })
    try {
        $md = @(Get-ChildItem -LiteralPath (Join-Path $env:SystemRoot 'Minidump') -Filter *.dmp -ErrorAction Stop | Sort-Object LastWriteTime -Descending)
        $out.minidumps = @($md | Select-Object -First 10 | ForEach-Object { [ordered]@{ file = $_.Name; time = $_.LastWriteTime.ToString('o') } })
    } catch { $out.minidumps = 'needs admin to list' }

    if ($bugchecks.Count) { Add-Finding 'high' 'health' "$($bugchecks.Count) blue screen(s) in 14 days" (($out.bugChecks | Select-Object -First 2 | ForEach-Object { $_.message }) -join ' | ') 'Keep minidumps; investigate driver/memory/overclock stability before any cleanup of dump files.' }
    if ($unexpected.Count) { Add-Finding 'medium' 'health' "$($unexpected.Count) unexpected shutdown(s) in 14 days" 'Kernel-Power 41: the PC lost power or hard-reset.' 'Check PSU, overclocks/undervolts (PBO, Curve Optimizer, EXPO) and temperatures.' }
    if ($whea.Count) { Add-Finding 'high' 'health' "$($whea.Count) WHEA hardware error event(s) in 14 days" 'CPU/memory/PCIe errors are commonly caused by unstable overclocks (PBO/Curve Optimizer/EXPO) or failing hardware.' 'Return CPU/memory settings to stock to test, update BIOS, and re-check.' }
    if ($tdr.Count) { Add-Finding 'medium' 'health' "$($tdr.Count) GPU driver timeout(s) (TDR) in 14 days" 'Display driver stopped responding and recovered.' 'Clean-update the GPU driver via Adrenalin (Factory Reset option), check GPU overclock/undervolt and power cables.' }
    if ($disk.Count -gt 5) { Add-Finding 'medium' 'health' "$($disk.Count) disk/file-system warnings in 14 days" 'From disk, Ntfs, stornvme or storahci.' 'Check SMART health; back up data.' }
    foreach ($c in $crashGroups | Where-Object { $_.count -ge 3 }) { Add-Finding 'low' 'health' "$($c.app) crashed $($c.count) times in 14 days" 'Application Error 1000.' 'Verify game files in the launcher; update or reinstall the app.' }
    $out
}

# ============================================================ security (report only)
Invoke-Section 'security' {
    $out = [ordered]@{ note = 'Reported only. This skill never disables or weakens these.' }
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        $out.defender = [ordered]@{ antivirusEnabled = $mp.AntivirusEnabled; realTimeProtection = $mp.RealTimeProtectionEnabled; tamperProtection = $mp.IsTamperProtected; signatureAgeDays = $mp.AntivirusSignatureAge; quickScanAgeDays = $mp.QuickScanAge }
        if (-not $mp.RealTimeProtectionEnabled) { Add-Finding 'high' 'security' 'Defender real-time protection is off' 'Unless another antivirus is active, the PC is unprotected.' 'Turn it back on in Windows Security > Virus & threat protection.' }
        if ($mp.AntivirusSignatureAge -gt 7) { Add-Finding 'medium' 'security' "Defender signatures are $($mp.AntivirusSignatureAge) days old" '' 'Windows Security > Virus & threat protection > Protection updates.' }
    } catch { $out.defender = 'unavailable' }
    try { $out.antivirusProducts = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop | ForEach-Object { $_.displayName }) } catch { }
    try { $out.firewall = @(Get-NetFirewallProfile -ErrorAction Stop | ForEach-Object { [ordered]@{ profile = $_.Name; enabled = [bool]$_.Enabled } })
          foreach ($f in $out.firewall) { if (-not $f.enabled) { Add-Finding 'high' 'security' "Firewall $($f.profile) profile is off" '' 'Turn it back on in Windows Security > Firewall & network protection.' } } } catch { }
    $out.uacEnabled = ((Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA') -ne 0)
    if (-not $out.uacEnabled) { Add-Finding 'high' 'security' 'User Account Control is disabled' '' 'Re-enable UAC.' }
    $sb = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' 'UEFISecureBootEnabled'
    $out.secureBoot = if ($null -eq $sb) { 'unknown/legacy BIOS' } elseif ($sb -eq 1) { 'On' } else { 'Off' }
    if ($sb -eq 0) { Add-Finding 'medium' 'security' 'Secure Boot is off' 'Several anti-cheat systems (e.g. Vanguard, Javelin/EA, FACEIT for some titles) require it, and it protects boot integrity.' 'Enable in BIOS (requires UEFI/GPT boot).' }
    $sac = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' 'VerifiedAndReputablePolicyState'
    $out.smartAppControl = switch ($sac) { 0 { 'Off' } 1 { 'On' } 2 { 'Evaluation' } default { 'unknown' } }
    try { $tpm = Get-CimInstance -Namespace root/cimv2/security/microsofttpm -ClassName Win32_Tpm -ErrorAction Stop; $out.tpm = [ordered]@{ present = $true; enabled = $tpm.IsEnabled_InitialValue; version = $tpm.SpecVersion } } catch { $out.tpm = 'needs admin' }
    try {
        $sh = New-Object -ComObject Shell.Application
        $bl = $sh.NameSpace("$env:SystemDrive\").Self.ExtendedProperty('System.Volume.BitLockerProtection')
        $out.bitlockerSystemDrive = switch ($bl) { 1 { 'On' } 2 { 'Off' } 3 { 'Encrypting' } 4 { 'Decrypting' } 5 { 'Suspended' } 6 { 'On (locked)' } default { 'Not available' } }
    } catch { $out.bitlockerSystemDrive = 'unknown' }
    if ($audit.gaming -and $audit.gaming.vbs) { $out.vbs = $audit.gaming.vbs }
    else { try { $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop; $out.vbs = [ordered]@{ vbsStatus = $dg.VirtualizationBasedSecurityStatus; memoryIntegrityRunning = (@($dg.SecurityServicesRunning) -contains 2) } } catch { } }
    $out
}

# ============================================================ developer environment
Invoke-Section 'dev' {
    $out = [ordered]@{}
    $tools = [ordered]@{}
    foreach ($t in 'git', 'node', 'npm', 'pnpm', 'yarn', 'python', 'pip', 'uv', 'dotnet', 'go', 'cargo', 'docker', 'wsl') { $tools[$t] = [bool](Get-Command $t -ErrorAction SilentlyContinue) }
    $out.tools = $tools
    $vhdx = @()
    $vhdxGlobs = @("$env:LOCALAPPDATA\Packages\*\LocalState\*.vhdx", "$env:LOCALAPPDATA\wsl\*\*.vhdx", "$env:LOCALAPPDATA\Docker\wsl\*\*.vhdx", "$env:LOCALAPPDATA\Docker\wsl\*.vhdx")
    foreach ($glob in $vhdxGlobs) {
        $vhdx += @(Get-Item -Path $glob -Force -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ path = $_.FullName; sizeBytes = $_.Length; lastWrite = $_.LastWriteTime.ToString('yyyy-MM-dd') } })
    }
    $out.virtualDisks = $vhdx
    $big = @($vhdx | Where-Object { $_.sizeBytes -gt 20GB })
    foreach ($v in $big) { Add-Finding 'info' 'dev' "Large WSL/Docker virtual disk: $(Format-WMBytes $v.sizeBytes)" $v.path 'VHDX files do not shrink automatically. Prune inside the distro/Docker first, then compact (Docker Desktop: Troubleshoot > Clean/Purge data, or wsl --manage <distro> --set-sparse true). Manual step - review before doing it.' }

    $defaults = @('Documents\Claude Code', 'source', 'Projects', 'repos', 'dev', 'code', 'Documents\GitHub') | ForEach-Object { Join-Path $env:USERPROFILE $_ }
    $roots = @(@($defaults) + @($DevRoots) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
    $out.devRoots = $roots
    if ($Mode -eq 'Deep' -or $DevRoots.Count) {
        $nm = New-Object System.Collections.Generic.List[object]
        foreach ($r in $roots) {
            foreach ($d in [WinMaint.Fs]::FindDirs($r, 'node_modules', 5, 30)) {
                $m = [WinMaint.Fs]::Measure($d, 0, $null, $null, 5)
                $nm.Add([ordered]@{ path = $d; sizeBytes = $m.TotalBytes; truncated = $m.Truncated; lastWrite = (Get-Item -LiteralPath $d -Force).LastWriteTime.ToString('yyyy-MM-dd') })
            }
        }
        $out.nodeModules = @($nm | Sort-Object { $_.sizeBytes } -Descending | Select-Object -First 25)
        $out.nodeModulesTotalBytes = [int64](($nm | Measure-Object -Property sizeBytes -Sum).Sum)
        if ($out.nodeModulesTotalBytes -gt 5GB) { Add-Finding 'info' 'dev' "$(Format-WMBytes $out.nodeModulesTotalBytes) in node_modules folders across your projects" "$($nm.Count) folders found." 'Review-only: delete node_modules yourself in projects you are not actively working on (npm/pnpm install restores them).' }
    }
    $out
}

# ============================================================ deep extras (admin)
Invoke-Section 'deep' {
    $out = [ordered]@{}
    if ($isAdmin) {
        try {
            $a = (DISM.exe /Online /Cleanup-Image /AnalyzeComponentStore /English 2>&1 | Out-String)
            $out.componentStore = [ordered]@{
                actualSize = ([regex]::Match($a, 'Actual Size of Component Store\s*:\s*(.+)')).Groups[1].Value.Trim()
                reclaimablePackages = ([regex]::Match($a, 'Number of Reclaimable Packages\s*:\s*(\d+)')).Groups[1].Value
                cleanupRecommended = ([regex]::Match($a, 'Component Store Cleanup Recommended\s*:\s*(\w+)')).Groups[1].Value
            }
            if ($out.componentStore.cleanupRecommended -eq 'Yes') { Add-Finding 'low' 'cleanup' 'Windows component store cleanup recommended' "$($out.componentStore.reclaimablePackages) reclaimable packages." 'Approve the component-store target in Clean mode (no /ResetBase).' }
        } catch { $out.componentStore = "failed: $($_.Exception.Message)" }
        try {
            $h = (DISM.exe /Online /Cleanup-Image /CheckHealth /English 2>&1 | Out-String)
            $out.imageHealth = if ($h -match 'No component store corruption detected') { 'Healthy' } elseif ($h -match 'repairable') { 'Repairable corruption' } else { 'See DISM output' }
            if ($out.imageHealth -ne 'Healthy') { Add-Finding 'medium' 'health' "Windows image health: $($out.imageHealth)" 'DISM /CheckHealth.' 'Run DISM /Online /Cleanup-Image /RestoreHealth then sfc /scannow (admin, with approval).' }
        } catch { }
        try { $out.shadowStorage = (vssadmin list shadowstorage 2>&1 | Out-String).Trim() } catch { }
    } else {
        $out.note = 'Run elevated for component store analysis, image health check and restore-point storage.'
    }
    $out
}

# ============================================================ output
$audit.findings = @($findings | Sort-Object @{ Expression = { @{ high = 0; medium = 1; low = 2; info = 3 }[$_.severity] } }, area)
$audit.finishedAt = (Get-Date).ToString('o')
$audit.durationSeconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
$audit.driveFree = Get-WMDriveFree

$dataDir = Initialize-WMDataDir
$stamp = Get-WMTimestamp
$base = "audit-$stamp-$($Mode.ToLower())$(if ($Label) { '-' + ($Label -replace '[^\w-]', '') })"
$jsonPath = Join-Path $dataDir "reports\$base.json"
$mdPath = Join-Path $dataDir "reports\$base.md"
$audit | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

# ---------- markdown
$md = New-Object System.Text.StringBuilder
function L([string]$s = '') { [void]$md.AppendLine($s) }
function Esc([string]$s) { if ($null -eq $s) { return '' } return ($s -replace '\|', '\|' -replace "`r?`n", ' ') }
L "# Windows maintenance audit - $Mode"
L ''
L "Generated $((Get-Date).ToString('yyyy-MM-dd HH:mm')) on **$env:COMPUTERNAME** - $(if ($isAdmin) { 'elevated' } else { 'standard user (some checks limited)' }) - read-only - $($audit.durationSeconds)s"
if ($Label) { L "Label: **$Label**" }
L ''
if ($audit.system) {
    $s = $audit.system
    L '## System'
    L "- $($s.os) $($s.displayVersion) (build $($s.build)), installed $($s.installDate), up $($s.uptimeDays) days"
    L "- $($s.cpu) - $($s.cores)C/$($s.threads)T - $($s.ramGB) GB RAM - $($s.motherboard) - BIOS $($s.bios)"
    L ''
}
$hi = @($audit.findings | Where-Object severity -eq 'high').Count; $me = @($audit.findings | Where-Object severity -eq 'medium').Count
L "## Findings ($hi high, $me medium, $(@($audit.findings).Count) total)"
L ''
if (@($audit.findings).Count) {
    L '| Severity | Area | Finding | Detail | Recommendation |'
    L '|---|---|---|---|---|'
    foreach ($f in $audit.findings) { L "| $($f.severity) | $($f.area) | $(Esc $f.title) | $(Esc $f.detail) | $(Esc $f.recommendation) |" }
} else { L 'No issues found in the selected sections.' }
L ''
if ($audit.storage) {
    L '## Storage'
    L '| Drive | Label | Free | Size | Free % | Disk | Media |'
    L '|---|---|---|---|---|---|---|'
    foreach ($v in $audit.storage.volumes) { L "| $($v.drive) | $(Esc $v.label) | $(Format-WMBytes $v.freeBytes) | $(Format-WMBytes $v.sizeBytes) | $($v.freePct)% | $(Esc $v.disk) | $($v.mediaType) $($v.busType) |" }
    L ''
    $dl = @($audit.storage.physicalDisks | ForEach-Object { "$($_.name): $($_.health)$(if ($null -ne $_.temperatureC) { ", $($_.temperatureC) C" })$(if ($null -ne $_.wearPct) { ", wear $($_.wearPct)%" })" })
    L "Disks: $($dl -join '; '). TRIM: $(if ($null -eq $audit.storage.trimEnabled) { 'unknown' } elseif ($audit.storage.trimEnabled) { 'on' } else { 'OFF' })."
    L ''
}
if ($audit.cleanup) {
    $c = $audit.cleanup
    L '## Recoverable storage (estimate, nothing deleted)'
    L "- Tier 1 (low risk): **$(Format-WMBytes $c.estimatedTier1Bytes)**"
    L "- Tier 2 (has a cost, explain first): **$(Format-WMBytes $c.estimatedTier2Bytes)**"
    L "- Tier 3 (review-only / your files): $(Format-WMBytes $c.reviewOnlyTier3Bytes)"
    L ''
    L '| Id | Target | Tier | Scope | Total | Est. recoverable | Notes |'
    L '|---|---|---|---|---|---|---|'
    foreach ($t in $c.targets | Where-Object { $_.totalBytes -gt 0 -or $_.measurementIncomplete } | Sort-Object { $_.tier }, { - $_.estimatedRecoverableBytes }) {
        $notes = @()
        if ($t.blockingProcesses.Count) { $notes += "close: $($t.blockingProcesses -join ', ')" }
        if ($t.measurementIncomplete) { $notes += 'measurement incomplete (needs admin)' }
        if ($t.method -eq 'tool-command' -and -not $t.toolAvailable) { $notes += 'tool not on PATH' }
        if ($t.method -eq 'report-only') { $notes += 'report only' }
        L "| $($t.id) | $(Esc $t.label) | $($t.tier) | $($t.scope) | $(Format-WMBytes $t.totalBytes) | $(Format-WMBytes $t.estimatedRecoverableBytes) | $(Esc ($notes -join '; ')) |"
    }
    L ''
}
if ($audit.startup) {
    L "## Startup ($($audit.startup.enabledCount) enabled, $($audit.startup.candidateCount) optional candidates)"
    L '| Name | Source | Enabled | Class | Why |'
    L '|---|---|---|---|---|'
    foreach ($i in $audit.startup.items | Sort-Object { @{ candidate = 0; review = 1; protected = 2 }[$_.class] }, name) { L "| $(Esc $i.name) | $($i.source) | $($i.enabled) | $($i.class) | $(Esc $i.reason) |" }
    L ''
}
if ($audit.services) {
    $sv = $audit.services
    L "## Services ($($sv.autoStartCount) automatic of $($sv.totalServices); $($sv.runningCount) running)"
    $rows = @($sv.items | Where-Object { $_.class -ne 'protected' })
    if ($rows.Count) {
        L '| Service | Display name | Start | State | Class |'
        L '|---|---|---|---|---|'
        foreach ($r in $rows) { L "| $($r.name) | $(Esc $r.displayName) | $($r.startMode)$(if ($r.delayed) { ' (delayed)' }) | $($r.state) | $($r.class) |" }
    }
    L "Protected services present (never changed): $((@($sv.items | Where-Object class -eq 'protected' | ForEach-Object { $_.name })) -join ', ')"
    L ''
}
if ($audit.apps) {
    $a = $audit.apps
    L "## Apps ($($a.appxInstalledCount) Store apps, $($a.win32ProgramCount) desktop programs)"
    if ($a.appxCandidates.Count) {
        L '| Store package | What it is | Note |'
        L '|---|---|---|'
        foreach ($x in $a.appxCandidates) { L "| $($x.name) | $(Esc $x.label) | $(Esc $x.note) |" }
    } else { L 'No preinstalled bloat candidates found.' }
    if ($a.suspectPrograms.Count) { L ''; L "Suspect programs: $((@($a.suspectPrograms | ForEach-Object { "$($_.name) ($($_.label))" })) -join '; ')" }
    L ''
}
if ($audit.performance) {
    $p = $audit.performance
    L '## Performance snapshot'
    L "- Memory: $($p.memory.usedPct)% used ($($p.memory.availableMB) MB free of $($p.memory.totalMB) MB); commit available $($p.memory.commitAvailableMB) MB of $($p.memory.commitLimitMB) MB"
    L "- Page file: $(if ($p.pagefile.systemManaged) { 'system managed' } else { 'manual' })"
    L "- Top CPU ($($p.sampleSeconds)s sample): $((@($p.topCpu | Select-Object -First 6 | ForEach-Object { "$($_.name) $($_.cpuPct)%" })) -join ', ')"
    L "- Top memory: $((@($p.topMemory | Select-Object -First 6 | ForEach-Object { "$($_.name) $($_.workingSetMB) MB" })) -join ', ')"
    L ''
}
if ($audit.gaming) {
    $g = $audit.gaming
    L '## Gaming'
    L "- Power plan: $($g.powerPlan.activeName); Game Mode: $($g.gameMode); HAGS: $($g.hardwareGpuScheduling); windowed optimisations: $($g.windowedGameOptimizations); VRR: $($g.variableRefreshRate)"
    L "- Background recording: $(if ($g.gameCapture.backgroundRecording) { 'on' } else { 'off' }); VBS: $(if ($g.vbs) { $g.vbs.vbsStatus } else { 'unknown' }), Memory Integrity running: $(if ($g.vbs) { $g.vbs.memoryIntegrityRunning } else { 'unknown' })"
    foreach ($v in $g.gpus) { L "- GPU: $($v.name) - driver $($v.driverVersion) ($($v.driverDate))$(if ($v.refreshHz) { " - $($v.resolution) @ $($v.refreshHz) Hz$(if ($v.maxRefreshHz) { " (max reported $($v.maxRefreshHz))" })" } else { ' - no active display' })" }
    L "- RAM: $((@($g.memoryModules | ForEach-Object { "$($_.sizeGB) GB $($_.type) $($_.configuredMTs)/$($_.ratedMTs) MT/s in $($_.slot)" })) -join '; ')"
    $sw = @($g.software.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { $_.Key })
    L "- Detected (protected): $($sw -join ', ')"
    if ($g.antiCheat.Count) { L "- Anti-cheat components (protected): $($g.antiCheat -join ', ')" }
    foreach ($l in $g.gameLibraries) { L "- Library: $($l.platform) $($l.path) ($($l.mediaType), $($l.freePct)% free)" }
    foreach ($n in $g.network) { L "- Network: $($n.name) $($n.media) $($n.linkSpeed)" }
    L ''
}
if ($audit.drivers) {
    $d = $audit.drivers
    L '## Drivers and updates'
    L "- Last Windows update installed: $($d.lastUpdateInstalled)"
    if ($d.amdSoftware) { L "- $($d.amdSoftware.name) $($d.amdSoftware.version)" }
    L "- Problem devices: $(if ($d.problemDevices.Count) { (@($d.problemDevices | ForEach-Object { "$($_.name) (code $($_.errorCode))" })) -join '; ' } else { 'none' })"
    if ($d.wingetUpgrades) { L ''; L '```'; foreach ($w in $d.wingetUpgrades) { L $w }; L '```' }
    L ''
}
if ($audit.health) {
    $h = $audit.health
    L '## Health (last 14 days)'
    L "- Blue screens: $($h.bugChecks.Count); unexpected shutdowns: $($h.unexpectedShutdowns); WHEA: $($h.wheaEvents); GPU timeouts: $($h.gpuDriverTimeouts); disk warnings: $($h.diskEvents); app hangs: $($h.appHangs)"
    if ($h.appCrashes.Count) { L "- App crashes: $((@($h.appCrashes | ForEach-Object { "$($_.app) x$($_.count)" })) -join ', ')" }
    if ($h.pendingReboot.Count) { L "- Pending restart: $($h.pendingReboot -join ', ')" }
    L ''
}
if ($audit.security) {
    $s = $audit.security
    L '## Security (report only)'
    $def = if ($s.defender -is [string]) { $s.defender } else { "RTP $($s.defender.realTimeProtection), tamper $($s.defender.tamperProtection), signatures $($s.defender.signatureAgeDays)d" }
    L "- Defender: $def; AV products: $($s.antivirusProducts -join ', ')"
    L "- Firewall: $((@($s.firewall | ForEach-Object { "$($_.profile)=$($_.enabled)" })) -join ', '); UAC: $($s.uacEnabled); Secure Boot: $($s.secureBoot); Smart App Control: $($s.smartAppControl); BitLocker ($env:SystemDrive): $($s.bitlockerSystemDrive)"
    L ''
}
if ($audit.dev) {
    $d = $audit.dev
    L '## Developer environment'
    L "- Tools: $((@($d.tools.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { $_.Key })) -join ', ')"
    foreach ($v in $d.virtualDisks) { L "- VHDX: $($v.path) - $(Format-WMBytes $v.sizeBytes)" }
    if ($d.nodeModules) { L "- node_modules total: $(Format-WMBytes $d.nodeModulesTotalBytes) (review-only)"; foreach ($n in $d.nodeModules | Select-Object -First 10) { L "  - $($n.path) - $(Format-WMBytes $n.sizeBytes) (last write $($n.lastWrite))" } }
    L ''
}
if ($audit.deep) {
    L '## Deep checks'
    if ($audit.deep.componentStore) { L "- Component store: $($audit.deep.componentStore | ConvertTo-Json -Compress)" }
    if ($audit.deep.imageHealth) { L "- Image health: $($audit.deep.imageHealth)" }
    if ($audit.deep.note) { L "- $($audit.deep.note)" }
    L ''
}
if ($audit.errors.Count) { L '## Audit errors'; foreach ($e in $audit.errors) { L "- $e" }; L '' }
L "Snapshot: ``$jsonPath``"
$md.ToString() | Set-Content -LiteralPath $mdPath -Encoding UTF8

if (-not $Quiet) { Write-Host '' ; Write-Output $md.ToString() }
Write-Output "AUDIT_JSON: $jsonPath"
Write-Output "AUDIT_MD: $mdPath"
