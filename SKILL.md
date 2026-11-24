---
name: windows-maintenance
description: Clean, diagnose and optimise a Windows 11 gaming + development PC safely. Modes - audit (read-only analysis), clean (temp/cache/leftover files), debloat (unneeded apps, startup items, services), optimise (gaming performance, drivers, power, resources), deep (everything plus a maintenance plan). Use when the user runs /windows-maintenance, or asks to clean up, speed up, debloat, tune, health-check or free disk space on their Windows PC. Always audits read-only first, estimates recoverable space, and changes nothing without explicit approval.
argument-hint: "[audit|clean|debloat|optimise|deep]"
---

# Windows maintenance

One cohesive, dependency-free maintenance workflow for a Windows 11 gaming and
development PC. Built-in Windows tooling only (PowerShell, CIM, powercfg, DISM,
pnputil). No third-party script is downloaded or run.

Requested mode: **$ARGUMENTS** (empty means `audit`).

## Non-negotiable rules

1. **Read-only first.** Every mode starts with `Invoke-Audit.ps1`. Never change anything in the same step as the assessment.
2. **Estimate before deleting.** Show per-target sizes and tier totals from the audit and the `Invoke-Clean.ps1` dry run before asking.
3. **Explicit approval for every change.** Ask in chat and list the exact target ids, entries, services, packages or settings. "Clean it up" approves only the plan you showed, not later or bigger targets. Tier-2 items need their cost explained. Tier-3 items (Recycle Bin, protected startup entries, non-candidate apps) each need a separate yes that names that item.
4. **Protect user data.** Never delete or modify personal files (Documents, Desktop, Pictures, Videos, Music, Downloads, OneDrive), game saves, development projects and repos, credentials and keys (`.ssh`, `.aws`, `.gnupg`, Credential Manager, browser logins/cookies), or application settings. `config\protected.json` enforces this in code. Never edit that file to get past a refusal.
5. **Preserve gaming and streaming.** Steam, Xbox app / Game Pass / Gaming Services / Game Bar, Microsoft Store, AMD Adrenalin and chipset services (including `amd3dvcacheSvc`), Moonlight, Sunshine/Apollo, Parsec, OBS, virtual display drivers, Tailscale/ZeroTier and every anti-cheat (EAC, BattlEye, Vanguard, FACEIT, EA AC, XIGNCODE, etc.) are protected. Scripts refuse to touch them.
6. **Never weaken security.** Do not disable or reconfigure Defender, Firewall, SmartScreen, UAC, Secure Boot, TPM, BitLocker, VBS/Memory Integrity, Windows Update or Smart App Control. Report their state only. If one is off, recommend turning it back on.
7. **No speculative tweaks.** Only apply changes that are documented, measurable and reversible (see `references/optimise-guide.md`). Never apply registry "performance" hacks, network/Nagle tweaks, timer/HPET/bcdedit changes, mitigation disabling, service mass-disabling, or tweak packs.
8. **Back up first.** Before any configuration change run `Backup-State.ps1`. Before system-level changes (services, Appx removal, HKLM startup, DISM, power plan) also create a restore point with `New-RestorePoint.ps1` (elevated).
9. **Third-party scripts.** Never run `irm ... | iex` or any downloaded script. If the user wants an external tool (e.g. WinUtil, Win11Debloat), download it into a new empty folder and read the whole script. Report exactly what it would change and pin the commit/version. Run it only after explicit approval, and never as a shortcut around these rules.
10. **Report honestly.** Show the before-and-after report. Name what was skipped, what failed, and what needs a restart. Never claim space was freed without the measured numbers.

## Paths and how to run scripts

```text
Skill:    %USERPROFILE%\.claude\skills\windows-maintenance
Scripts:  <skill>\scripts            Config: <skill>\config
Output:   %LOCALAPPDATA%\WindowsMaintenance\{reports,results,backups,journal.jsonl}
```

Run every script like this (process-scoped execution policy, nothing persisted):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\skills\windows-maintenance\scripts\<Script>.ps1" <args>
```

Use `powershell.exe` instead of `pwsh` if PowerShell 7 is missing. Scripts print machine-readable marker lines (`AUDIT_JSON:`, `AUDIT_MD:`, `CLEAN_RESULT:`, `CHANGE_RESULT:`, `BACKUP_DIR:`, `RESTORE_POINT:`, `REPORT_MD:`, `ELEVATION_REQUIRED:`). The audit takes about 20–60 s (Deep is longer), so allow a 5-minute timeout.

### Elevation

Claude's shell is normally not elevated. Scripts never self-elevate. They report `ELEVATION_REQUIRED` and change nothing. For admin steps, tell the user a UAC prompt will appear and run:

```powershell
Start-Process pwsh -Verb RunAs -Wait -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$env:USERPROFILE\.claude\skills\windows-maintenance\scripts\<Script>.ps1",<args...>
```

The elevated window's output is not captured. Afterwards read the result from the newest file in `%LOCALAPPDATA%\WindowsMaintenance\results` or `reports`, or from the tail of `journal.jsonl`. You can also give the user the command to paste into an Administrator terminal. The user approving the UAC prompt is their consent for that one step only.

## Scripts

| Script | Changes system? | Purpose |
|---|---|---|
| `Invoke-Audit.ps1 -Mode <m> [-Label before\|after] [-DevRoots ...] [-IncludeWinget]` | No | Read-only audit → JSON snapshot + Markdown report |
| `Invoke-Clean.ps1 -Targets <ids\|tier1> [-Execute] [-AllowTier3]` | Only with `-Execute` | Re-measures and cleans catalog targets |
| `Invoke-Change.ps1 -Action <a> -Name <n> [-Execute]` | Only with `-Execute` | One reversible change: startup, service→Manual, Appx removal, power plan, Game Mode |
| `Undo-Change.ps1 -List \| -Id <id> \| -All [-Execute]` | Only with `-Execute` | Reverses journaled changes |
| `Backup-State.ps1` | No | Exports startup keys, services, apps, tasks, power plan |
| `New-RestorePoint.ps1 [-EnableSystemProtection]` | Creates restore point (admin) | Verifies creation; reports the Windows 24 h limit honestly |
| `Compare-Audit.ps1 [-Before f] [-After f]` | No | Before-and-after maintenance report |

## Workflow (all modes)

1. **Assess.** Run `Invoke-Audit.ps1 -Mode <mode> -Label before`. Read the Markdown it prints. Open the JSON only for detail.
2. **Report and plan.** Synthesise; don't paste the whole report. Use the "Report format" below. Group proposed actions:
   - **A. Safe and reversible**: tier-1 cleanup, disabling optional startup items, switching to Balanced, enabling Game Mode.
   - **B. Has a cost or needs admin**: tier-2 cleanup, services → Manual, Appx removal, DISM component cleanup.
   - **C. Your decision / manual only**: Recycle Bin, Downloads, node_modules, WSL/Docker disk compaction, BIOS (EXPO/XMP), hardware, uninstalling desktop programs, anything protected.
3. **Ask.** Request explicit approval per group or item. Stop and wait. Do not assume consent.
4. **Protect.** Run `Backup-State.ps1`. If any approved item is system-level, create a restore point (elevated). If System Protection is off, ask before using `-EnableSystemProtection`.
5. **Execute.** Run the dry run first (no `-Execute`) and confirm it matches what was approved. Then execute exactly the approved items. Never force-close apps. If a target reports `skipped-app-open`, ask the user to close the app and re-run that target.
6. **Verify and report.** Run `Invoke-Audit.ps1 -Mode <mode> -Label after`, then `Compare-Audit.ps1`. Present the before-and-after report (freed space per drive, items changed, findings resolved, anything skipped/failed, restart needed). Mention `Undo-Change.ps1 -List` for rollback.

## Modes

### audit (default)
Run the read-only audit (`-Mode Audit`), then present the report and a prioritised recommendation list. Make no changes. Offer the relevant follow-up mode(s).

### clean
`Invoke-Audit.ps1 -Mode Clean` measures every target in `config/clean-targets.json`. Present:
- Tier totals, and a table of targets above about 50 MB with size, tier and any "close X first" or "needs admin" notes.
- Tier 1: regenerable temp, caches, logs, crash reports. Offer as one group.
- Tier 2: explain the cost first. Shader caches cause first-launch stutter. Diagnostic dumps destroy crash evidence: check the health section for BSODs/TDRs. Installer leftovers lose the offline reinstall copy. Steam web cache may sign out web views. A full Yarn/npm clean means re-downloads. Component store cleanup is slow.
- Tier 3: report only. The Recycle Bin is the user's deleted files and needs its own explicit yes plus `-AllowTier3`. Windows.old and the Windows Update cache: point to Settings > System > Storage > Temporary files. Hibernation file and page file: never.
- Dev: package caches via their own tools (`npm cache verify`, `pip cache purge`, `pnpm store prune`, …). node_modules and build outputs in projects are **review-only**: list them, and let the user delete per project.
Then run `Invoke-Clean.ps1 -Targets <approved ids>` as a dry run, then with `-Execute`. Admin targets go in a separate elevated run.

### debloat
`Invoke-Audit.ps1 -Mode Debloat`. Read `references/debloat-guide.md`. Present:
- Startup entries classed `candidate` (with reason) and `review` (unknown: explain what each is if you can tell from the command path). Never propose `protected` ones. If the user explicitly names one (e.g. "stop Steam auto-starting"), use `-AllowProtectedStartup`.
- Store apps on the candidate list, with notes ("keep if you use Phone Link"…).
- Third-party auto-start services: propose Manual only for software the user confirms they don't need at boot. Optional Microsoft services: only those in the config list, framed as minor or privacy rather than performance.
- Suspect desktop programs (trialware, "optimizers", driver updaters, toolbars): recommend uninstall via Settings > Apps, or `winget uninstall --exact --id <id>` after approval, one at a time.
Apply each approved item with `Invoke-Change.ps1` (dry run, then `-Execute`). Expect small real-world gains. Say so plainly; debloating is about tidiness and background noise, not FPS.

### optimise
`Invoke-Audit.ps1 -Mode Optimise`. Read `references/optimise-guide.md`. Assess with evidence:
- Display refresh rate vs panel maximum; monitor wired to the iGPU.
- RAM configured vs rated speed (EXPO/XMP) and channel population.
- Power plan (Balanced recommended for Ryzen; required for dual-CCD X3D core parking), Game Mode, Game Bar presence (X3D), background recording, HAGS, windowed optimisations, VRR.
- GPU driver age and version (update through AMD Software only), problem devices, chipset software.
- Resource hogs at sample time, memory pressure, page file configuration.
- Stability evidence: WHEA, TDR (4101), BSODs, unexpected shutdowns, app/game crashes, disk warnings.
- Game library placement (HDD vs SSD) and free space; Ethernet link speed for streaming.
Only scriptable changes: `SetPowerPlan`, `SetGameMode`. Everything else is guided: give the exact Settings page (you may open it with `start ms-settings:<page>`) or the BIOS/vendor-app step for the user to do. Do not "optimise" things that are already at the recommended state.

### deep
Run `Invoke-Audit.ps1 -Mode Deep -Label before`, elevated if the user agrees. Elevation adds component store analysis, DISM CheckHealth, SMART wear/temperature, restore-point storage and full system-folder sizing. Deep also scans dev roots for node_modules and lists winget upgrades. Then write a **maintenance plan** covering:
1. Health and stability issues first (hardware errors, crashes, failing disks, security features off).
2. Storage: recoverable space by tier, with the specific approval list.
3. Debloat: startup, apps, services candidates.
4. Optimisation: evidence-backed findings, each with expected impact and who performs it (script, Settings, BIOS, hardware).
5. Routine schedule, e.g. monthly Clean tier 1 and a quarterly audit.
Execute nothing until the user approves sections of the plan, then follow the workflow above. If an image-health problem appears, propose `DISM /Online /Cleanup-Image /RestoreHealth` then `sfc /scannow` (elevated, with approval). These are repairs, never routine.

## Report format

```markdown
## Windows maintenance — <mode> (<date>)
**Summary:** 1–3 sentences: overall health, biggest issue, space recoverable.
### Health & stability   (only if findings)
### Storage              drives table; recoverable: tier 1 X GB, tier 2 Y GB, review-only Z GB
### Findings             ranked high→low, each with evidence → recommendation → who acts
### Proposed actions     A / B / C groups with exact ids/names and per-item impact
### Needs your decision  the approval question(s)
```

After execution, follow the same structure with the `Compare-Audit.ps1` numbers: before → after per drive, what changed, what was skipped and why, restart needed, how to undo.

## Never do (even if asked casually; explain why and offer the safe alternative)

- Delete Prefetch, clear event logs, delete restore points or shadow copies, use `DISM /ResetBase`, delete `C:\Windows\Installer` or WinSxS by hand, or stop Windows Update services to delete their files.
- Disable hibernation or the page file automatically, or "optimise" the page file size.
- Disable or delete services en masse, or set any service to Disabled. Never touch protected services.
- Remove Store, Xbox, Game Bar, Gaming Services, codecs, Edge/WebView2, OneDrive (unless the user asks to uninstall OneDrive themselves via Settings), runtimes, or GPU/audio control apps.
- Kill processes to make files deletable. Delete anything whose owner app is running.
- Follow junctions or symlinks, or widen an approved target to its parent.
- Run registry cleaners, driver updaters, "debloat everything" presets, or tweak packs.

## Reference files (read when the mode needs them)

- `references/safety-policy.md`: what is protected and why; how the guards work.
- `references/clean-catalog.md`: every cleanup target, tier rationale, and manual-only items.
- `references/debloat-guide.md`: classifying startup items, services and apps on a gaming/dev PC.
- `references/optimise-guide.md`: evidence-based gaming checks, and the list of rejected speculative tweaks.
- `references/source-review.md`: what was adopted from or rejected in WinUtil, Win11Debloat, windows-optimize, win-disk-cleaner, agentic-cleanup and system-doctor.
