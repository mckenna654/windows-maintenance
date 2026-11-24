# Source review

Reviewed 2026-11-24 by reading the repositories' scripts and configs (read-only; nothing was
executed). The skill vendors no code from them and has no runtime dependency on them.

## ChrisTitusTech/winutil
- **Adopted:** restore point before changes; "Run Disk Cleanup" and temp-file cleanup as concepts; Settings-backed toggles (Game Mode, End Task) as guidance; the conservative idea of setting services to *Manual* rather than Disabled.
- **Rejected:** `irm christitus.com/win | iex` delivery (unpinned remote code); `DISM /ResetBase` in its Disk Cleanup tweak; "BitLocker – Disable" listed under *Essential Tweaks* (a security feature); Ultimate Performance plan (the audit flags imported "Ultimate" plans on Ryzen desktops, where AMD recommends Balanced); Edge/OneDrive removal, IPv6/Teredo disable, svchost splitting, Storage Sense disable, Delivery Optimization disable (Game Pass/Store downloads use it), DNS changers, O&O ShutUp10 bundle.

## Raphire/Win11Debloat
- **Adopted:** its default-selected consumer Appx list as the basis for `appxCandidates`, with per-app notes; restore point by default; the preference for supported toggles.
- **Rejected:** removing `Microsoft.XboxApp` and other gaming packages by default (all Xbox/Gaming packages are protected here, since Game Bar is needed for X3D core parking and Game Pass); `ForceRemoveEdge`; `DisableDriverUpdates`; `DisableStorageSense`; `DisableBitlockerAutoEncryption`; broad AI/Copilot registry policy packs (pointed to Settings instead).

## prabhatp75/windows-optimize
- **Adopted:** diagnose → report → grouped consent (A safe / B admin / C user) workflow; disabling startup via `StartupApproved` (Task Manager's method) instead of deleting Run values; services to Manual, never deleted; rollback journal; never self-elevate; age-filtered temp cleaning; "out of scope" list (no defrag on SSD, no registry cleaners, no sfc/DISM unless corruption suspected).
- **Changed:** its High Performance power-plan default does not fit Ryzen desktops (AMD recommends Balanced), so this skill recommends Balanced instead.

## orzcls/win-disk-cleaner
- **Adopted:** modular target list with a dry-run preview; developer-cache and GPU-shader-cache locations; manual recommendations (move libraries, Storage settings).
- **Rejected (dangerous):** clearing **all event logs**; deleting **Prefetch**; `powercfg /h off` by default; **deleting restore points** (`vssadmin delete shadows`); `DISM /ResetBase`; stopping Windows Update services to delete files; wiping `C:\Windows\Installer\$PatchCache$`; deleting the whole Maven repository, `Zoom\data` (contains settings) and Spotify storage (offline downloads); `cleanmgr /sagerun` with every category flagged (includes Downloads on older builds); wholesale wildcard deletes without age filters or junction checks.

## zhiganov/agentic-cleanup
- **Adopted (core safety model):** discovery never grants deletion authority; scan → report → select → refresh → execute; policy-driven allow-list of targets with `rejectReparsePoint` and refresh-before-execution; distinguishing estimated vs. measured recovery and reporting both; never kill processes or follow junctions; tool-native cache GC (`npm` cacache via npm itself); Windows.old as manual-only; Config.Msi leftovers concept; never `/ResetBase`; per-run results and honest partial/failed reporting.
- **Simplified:** dropped its Python helpers, JSON schemas, WizTree integration and install manifests to keep the skill dependency-free (pure PowerShell + an inline C# walker).

## xenoxavier/system-doctor
- **Adopted:** RAM slot/speed inspection, SMART-style disk health, large-file awareness, GPU driver age check with vendor-tool update guidance (AMD: Adrenalin > Check for updates), plain-English final report.
- **Rejected (conflicts with a gaming PC):** force-killing `vgtray` (Riot Vanguard anti-cheat) and game launchers; **deleting** Run values for Steam/Discord (irreversible); disabling **SysMain** and setting services to *Disabled*; High Performance plan and "visual effects best performance" as defaults.
