# WinMaint.Common.ps1 - shared helpers for the windows-maintenance skill.
# Dot-source only. Compatible with Windows PowerShell 5.1 and PowerShell 7+.
# Contains no destructive code paths except Remove-WMContents, which is only
# called by Invoke-Clean.ps1 after every guard has passed.

$script:WM_SkillRoot = Split-Path -Parent $PSScriptRoot
$script:WM_DataRoot  = Join-Path $env:LOCALAPPDATA 'WindowsMaintenance'
$script:WM_Inaccessible = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------- C# helper
if (-not ('WinMaint.Fs' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
using System.Diagnostics;

namespace WinMaint {
    public class MeasureResult {
        public long TotalBytes; public long EligibleBytes;
        public long FileCount; public long EligibleCount;
        public bool Truncated; public int Errors; public bool Exists;
    }
    public class DeleteResult {
        public long DeletedBytes; public long DeletedFiles;
        public long SkippedLocked; public long SkippedExcluded; public long SkippedYoung;
        public int DirsRemoved; public int Errors; public bool Truncated;
        public List<string> ErrorSamples = new List<string>();
    }

    public static class Fs {
        static bool IsReparse(FileSystemInfo i) { return (i.Attributes & FileAttributes.ReparsePoint) != 0; }

        static bool Excluded(string name, HashSet<string> names, HashSet<string> exts) {
            if (names != null && names.Contains(name)) return true;
            if (exts != null) {
                string ext = Path.GetExtension(name);
                if (!string.IsNullOrEmpty(ext) && exts.Contains(ext)) return true;
            }
            return false;
        }

        static HashSet<string> ToSet(string[] items) {
            HashSet<string> s = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (items != null) foreach (string x in items) if (!string.IsNullOrEmpty(x)) s.Add(x);
            return s;
        }

        // Measures a file or directory. Never follows reparse points (junctions/symlinks).
        public static MeasureResult Measure(string path, int minAgeDays, string[] excludeNames, string[] excludeExts, int maxSeconds) {
            MeasureResult r = new MeasureResult();
            DateTime cutoff = DateTime.UtcNow.AddDays(-minAgeDays);
            HashSet<string> names = ToSet(excludeNames); HashSet<string> exts = ToSet(excludeExts);
            Stopwatch sw = Stopwatch.StartNew();
            if (File.Exists(path)) {
                r.Exists = true;
                try { FileInfo f = new FileInfo(path); r.TotalBytes = f.Length; r.FileCount = 1;
                      if (f.LastWriteTimeUtc < cutoff) { r.EligibleBytes = f.Length; r.EligibleCount = 1; } }
                catch { r.Errors++; }
                return r;
            }
            if (!Directory.Exists(path)) return r;
            r.Exists = true;
            Stack<DirectoryInfo> stack = new Stack<DirectoryInfo>();
            stack.Push(new DirectoryInfo(path));
            while (stack.Count > 0) {
                if (maxSeconds > 0 && sw.Elapsed.TotalSeconds > maxSeconds) { r.Truncated = true; break; }
                DirectoryInfo d = stack.Pop();
                IEnumerable<FileSystemInfo> items;
                try { items = d.EnumerateFileSystemInfos(); } catch { r.Errors++; continue; }
                try {
                    foreach (FileSystemInfo i in items) {
                        if (IsReparse(i)) continue;
                        DirectoryInfo sub = i as DirectoryInfo;
                        if (sub != null) { if (!Excluded(sub.Name, names, null)) stack.Push(sub); continue; }
                        FileInfo f = (FileInfo)i;
                        long len = 0; try { len = f.Length; } catch { r.Errors++; continue; }
                        r.TotalBytes += len; r.FileCount++;
                        bool excluded = Excluded(f.Name, null, exts);
                        if (!excluded && f.LastWriteTimeUtc < cutoff) { r.EligibleBytes += len; r.EligibleCount++; }
                    }
                } catch { r.Errors++; }
            }
            return r;
        }

        // Deletes FILES older than minAgeDays inside root (root itself is kept).
        // Skips reparse points, excluded directory/file names, locked files.
        // Removes directories that become empty (never the root).
        public static DeleteResult DeleteContents(string root, int minAgeDays, string[] excludeNames, string[] excludeExts, int maxSeconds) {
            DeleteResult r = new DeleteResult();
            if (!Directory.Exists(root)) return r;
            DirectoryInfo rootInfo = new DirectoryInfo(root);
            if (IsReparse(rootInfo)) { r.Errors++; r.ErrorSamples.Add("root is a reparse point: " + root); return r; }
            DateTime cutoff = DateTime.UtcNow.AddDays(-minAgeDays);
            Stopwatch sw = Stopwatch.StartNew();
            Walk(rootInfo, true, cutoff, ToSet(excludeNames), ToSet(excludeExts), sw, maxSeconds, r);
            return r;
        }

        static void Walk(DirectoryInfo d, bool isRoot, DateTime cutoff, HashSet<string> names, HashSet<string> exts,
                         Stopwatch sw, int maxSeconds, DeleteResult r) {
            if (maxSeconds > 0 && sw.Elapsed.TotalSeconds > maxSeconds) { r.Truncated = true; return; }
            List<FileSystemInfo> items;
            try { items = new List<FileSystemInfo>(d.EnumerateFileSystemInfos()); }
            catch (Exception e) { r.Errors++; if (r.ErrorSamples.Count < 10) r.ErrorSamples.Add(d.FullName + ": " + e.Message); return; }
            foreach (FileSystemInfo i in items) {
                if (maxSeconds > 0 && sw.Elapsed.TotalSeconds > maxSeconds) { r.Truncated = true; return; }
                if (IsReparse(i)) { r.SkippedExcluded++; continue; }
                if (Excluded(i.Name, names, (i is FileInfo) ? exts : null)) { r.SkippedExcluded++; continue; }
                DirectoryInfo sub = i as DirectoryInfo;
                if (sub != null) { Walk(sub, false, cutoff, names, exts, sw, maxSeconds, r); continue; }
                FileInfo f = (FileInfo)i;
                try {
                    if (f.LastWriteTimeUtc >= cutoff) { r.SkippedYoung++; continue; }
                    long len = f.Length;
                    if ((f.Attributes & FileAttributes.ReadOnly) != 0) f.Attributes = FileAttributes.Normal;
                    f.Delete();
                    r.DeletedBytes += len; r.DeletedFiles++;
                } catch (IOException) { r.SkippedLocked++; }
                catch (UnauthorizedAccessException) { r.SkippedLocked++; }
                catch (Exception e) { r.Errors++; if (r.ErrorSamples.Count < 10) r.ErrorSamples.Add(f.FullName + ": " + e.Message); }
            }
            if (!isRoot) {
                try {
                    using (IEnumerator<FileSystemInfo> en = d.EnumerateFileSystemInfos().GetEnumerator()) {
                        if (!en.MoveNext()) { d.Delete(false); r.DirsRemoved++; }
                    }
                } catch { /* in use or not empty: leave it */ }
            }
        }

        // Finds directories with an exact name under root, bounded by depth and time.
        // Does not descend into matches or reparse points.
        public static List<string> FindDirs(string root, string name, int maxDepth, int maxSeconds) {
            List<string> found = new List<string>();
            if (!Directory.Exists(root)) return found;
            Stopwatch sw = Stopwatch.StartNew();
            Stack<KeyValuePair<DirectoryInfo,int>> stack = new Stack<KeyValuePair<DirectoryInfo,int>>();
            stack.Push(new KeyValuePair<DirectoryInfo,int>(new DirectoryInfo(root), 0));
            while (stack.Count > 0) {
                if (maxSeconds > 0 && sw.Elapsed.TotalSeconds > maxSeconds) break;
                KeyValuePair<DirectoryInfo,int> cur = stack.Pop();
                IEnumerable<DirectoryInfo> subs;
                try { subs = cur.Key.EnumerateDirectories(); } catch { continue; }
                try {
                    foreach (DirectoryInfo s in subs) {
                        if (IsReparse(s)) continue;
                        if (string.Equals(s.Name, name, StringComparison.OrdinalIgnoreCase)) { found.Add(s.FullName); continue; }
                        if (s.Name.StartsWith(".") ) continue;
                        if (cur.Value + 1 < maxDepth) stack.Push(new KeyValuePair<DirectoryInfo,int>(s, cur.Value + 1));
                    }
                } catch { }
            }
            return found;
        }
    }
}
'@
}

# ---------------------------------------------------------------- basics
function Test-WMAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-WMDataDir {
    foreach ($d in @('', 'reports', 'backups', 'results')) {
        $p = Join-Path $script:WM_DataRoot $d
        if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }
    return $script:WM_DataRoot
}

function Get-WMTimestamp { return (Get-Date).ToString('yyyyMMdd-HHmmss') }

function Get-WMConfig([string]$Name) {
    $p = Join-Path (Join-Path $script:WM_SkillRoot 'config') "$Name.json"
    return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Format-WMBytes([double]$Bytes) {
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Get-WMSteamPath {
    try {
        $p = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction Stop).SteamPath
        if ($p) { return ([IO.Path]::GetFullPath(($p -replace '/', '\'))) }
    } catch { }
    return $null
}

# Expands %ENV% and %STEAM% tokens and normalises separators. Returns $null if a token cannot be resolved.
function Expand-WMPath([string]$Path) {
    $p = $Path
    if ($p -match '%STEAM%') {
        $steam = Get-WMSteamPath
        if (-not $steam) { return $null }
        $p = $p.Replace('%STEAM%', $steam)
    }
    $p = [Environment]::ExpandEnvironmentVariables($p)
    if ($p -match '%[^%]+%') { return $null }
    $p = $p -replace '/', '\'
    if ($p -match '^[A-Za-z]:\\?$') { return ($p.Substring(0, 2) + '\') }
    return $p.TrimEnd('\')
}

# Resolves a catalog path (with optional '*' segments) to existing file system paths.
function Resolve-WMPaths([string[]]$Paths) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($raw in $Paths) {
        $p = Expand-WMPath $raw
        if (-not $p) { continue }
        try {
            if ($p.Contains('*')) {
                foreach ($i in @(Get-Item -Path $p -Force -ErrorAction SilentlyContinue)) {
                    if ($i -and -not ($i.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $out.Add($i.FullName) }
                }
            } elseif ([IO.Directory]::Exists($p) -or [IO.File]::Exists($p)) {
                $out.Add($p)
            } else {
                # Not visible. Find the nearest existing ancestor; if it cannot be listed, the
                # target may exist behind an ACL (e.g. admin-only system folders).
                $anc = [IO.Path]::GetDirectoryName($p)
                while ($anc -and -not [IO.Directory]::Exists($anc)) { $anc = [IO.Path]::GetDirectoryName($anc) }
                if ($anc) { try { [void][IO.Directory]::GetFileSystemEntries($anc) } catch { $script:WM_Inaccessible.Add($p) } }
            }
        } catch { $script:WM_Inaccessible.Add($p) }
    }
    return ,$out.ToArray()
}

# ---------------------------------------------------------------- protection
$script:WM_Protected = $null
function Get-WMProtection {
    if (-not $script:WM_Protected) { $script:WM_Protected = Get-WMConfig 'protected' }
    return $script:WM_Protected
}

function Test-WMPathUnder([string]$Child, [string]$Parent) {
    $c = $Child.TrimEnd('\') + '\'
    $p = $Parent.TrimEnd('\') + '\'
    return $c.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)
}

# Returns $null when $Root may be cleaned, otherwise a human-readable refusal reason.
function Test-WMCleanRoot([string]$Root) {
    $prot = Get-WMProtection
    if (-not $Root) { return 'empty path' }
    try { $full = [IO.Path]::GetFullPath($Root).TrimEnd('\') } catch { return "invalid path: $Root" }
    if ($full.Length -le 3) { return "drive root refused: $full" }

    foreach ($n in $prot.neverCleanRoots) {
        $e = Expand-WMPath $n
        if ($e -and ($full.TrimEnd('\') -ieq $e.TrimEnd('\'))) { return "refused: $full is a top-level system/user folder" }
    }
    foreach ($pp in $prot.protectedPathPrefixes) {
        $e = Expand-WMPath $pp
        if (-not $e) { continue }
        if (Test-WMPathUnder $full $e) { return "refused: $full is inside protected location $e" }
        if (Test-WMPathUnder $e $full) { return "refused: $full contains protected location $e" }
    }
    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return "refused: $full is a junction/symlink" }
    }
    return $null
}

function Test-WMMatchAny([string]$Value, $Patterns) {
    if (-not $Value) { return $false }
    foreach ($p in $Patterns) { if ($Value -match $p) { return $true } }
    return $false
}

function Get-WMRunningProcesses([string[]]$Names) {
    $running = @()
    foreach ($n in $Names) {
        $p = Get-Process -Name $n -ErrorAction SilentlyContinue
        if ($p) { $running += $n }
    }
    return ,$running
}

# ---------------------------------------------------------------- measuring / deleting
function Measure-WMPath([string]$Path, [int]$MinAgeDays = 0, [int]$MaxSeconds = 20) {
    $prot = Get-WMProtection
    return [WinMaint.Fs]::Measure($Path, $MinAgeDays, [string[]]$prot.excludeDirNamesDuringDelete, [string[]]$prot.excludeFileExtensionsDuringDelete, $MaxSeconds)
}

function Remove-WMContents([string]$Root, [int]$MinAgeDays, [string[]]$ExtraExcludes, [int]$MaxSeconds = 300) {
    $reason = Test-WMCleanRoot $Root
    if ($reason) { throw $reason }
    $prot = Get-WMProtection
    $names = @([string[]]$prot.excludeDirNamesDuringDelete) + @($ExtraExcludes | Where-Object { $_ })
    return [WinMaint.Fs]::DeleteContents($Root, $MinAgeDays, [string[]]$names, [string[]]$prot.excludeFileExtensionsDuringDelete, $MaxSeconds)
}

function Get-WMDriveFree {
    $o = [ordered]@{}
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        if ($d.DriveType -eq 'Fixed' -and $d.IsReady) { $o[$d.Name.Substring(0, 2)] = $d.AvailableFreeSpace }
    }
    return $o
}

# ---------------------------------------------------------------- journal
function Write-WMJournal([hashtable]$Entry) {
    Initialize-WMDataDir | Out-Null
    $Entry['time'] = (Get-Date).ToString('o')
    if (-not $Entry.ContainsKey('id')) { $Entry['id'] = [guid]::NewGuid().ToString('N').Substring(0, 10) }
    $line = ($Entry | ConvertTo-Json -Depth 6 -Compress)
    Add-Content -LiteralPath (Join-Path $script:WM_DataRoot 'journal.jsonl') -Value $line -Encoding UTF8
    return $Entry['id']
}

function Get-WMJournal {
    $p = Join-Path $script:WM_DataRoot 'journal.jsonl'
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    return @(Get-Content -LiteralPath $p -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Write-WMElevationRequired([string]$What) {
    Write-Output "ELEVATION_REQUIRED: $What needs an elevated (Administrator) PowerShell. Nothing was changed."
}
