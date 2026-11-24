# Optimise guide: evidence-based gaming performance

Principle: change something only when the audit shows a measurable problem and the fix is a
documented, supported, reversible setting. If a setting is already at the recommended state,
say so and leave it.

## Checks and supported fixes

| Check (audit field) | Problem signal | Fix (who acts) |
|---|---|---|
| Refresh rate (`gaming.gpus[].refreshHz` vs `maxRefreshHz`) | High-refresh panel at 60 Hz | Settings > System > Display > Advanced display (user). Check cable (DP / HDMI 2.1) |
| Monitor on iGPU | iGPU has an active display while a dGPU exists | Plug the gaming monitor into the graphics card (user). Settings > System > Display > Graphics for per-app GPU |
| RAM speed (`memoryModules.configuredMTs`) | Below kit's rated speed (DDR5 at 4800, DDR4 at 2133/2400) | Enable EXPO/XMP in BIOS (user), then test stability. Never automated |
| RAM channels | Single stick, or sticks in the same channel | Hardware/slot change (user). Consult the motherboard manual for A2/B2 slots |
| Power plan | Non-Balanced on a Ryzen desktop (custom "Ultimate" plans from tweak tools are common) | `Invoke-Change.ps1 -Action SetPowerPlan -Name Balanced` (script, reversible). AMD recommends Balanced. On dual-CCD X3D (7900X3D/7950X3D/9900X3D/9950X3D) it is required for core parking |
| Game Mode | Off | `Invoke-Change.ps1 -Action SetGameMode -Value On` (script). Required for X3D core parking |
| Game Bar on X3D | Missing | Reinstall Xbox Game Bar from the Store (user) |
| AMD chipset / 3D V-Cache optimizer | Missing on an X3D CPU | Install AMD Chipset Software from amd.com (user) |
| Background recording | On and unused | Settings > Gaming > Captures (user) |
| HAGS | Report only | Settings > System > Display > Graphics > Change default graphics settings. Follow GPU vendor guidance; requires restart. Do not toggle speculatively |
| Windowed optimisations / VRR | Off | Same Settings page (user). Microsoft default is On for windowed optimisations |
| GPU driver age | > 180 days or TDRs present | AMD Software: Adrenalin Edition > Check for updates (user). Use Factory Reset install only when TDRs/corruption are present. No third-party driver updaters, no DDU unless troubleshooting |
| Problem devices | ConfigManager error ≠ 0 | Vendor driver or Windows Update (user) |
| Stability (WHEA, Kernel-Power 41, BSOD, TDR) | Any in 14 days | Test at stock (disable PBO/Curve Optimizer/GPU undervolt/EXPO one at a time), update BIOS, check PSU and temperatures. Fix stability before tuning anything |
| Disk health / free space | Not Healthy; < 15 % free | Back up; clean; move games with the launcher's Move feature |
| Game library on HDD | HDD media type | Move the most-played games to SSD (launcher Move feature) |
| Memory pressure | > 85 % used at idle sample | Identify heavy background apps (browsers, Electron apps, VMs, WSL). Close or remove from startup |
| Page file | Manual size | Recommend System managed unless the user has a reason. Never disable |
| Ethernet link | 100 Mbps | Cable/port (user) |
| Streaming host on Wi-Fi | Sunshine/Apollo with no wired link | Wire the host (user) |
| Windows Update | > 45 days since last update, pending restart | Settings > Windows Update. Restart before benchmarking |
| VBS / Memory Integrity | Report only | Never disable (security). Mention context only if the user asks about it |

## Rejected speculative tweaks (never apply; explain if asked)

These are common in tweak tools and videos but are unmeasurable, outdated, harmful, or weaken security:
- Registry network tweaks: `TcpAckFrequency`, `TCPNoDelay`/Nagle, `NetworkThrottlingIndex`, `SystemResponsiveness`, IRPStackSize, disabling IPv6/Teredo, DNS "optimizers". 
- Scheduler/timer tweaks: `Win32PrioritySeparation`, `bcdedit /set useplatformclock`/`disabledynamictick`/`tscsyncpolicy`, timer-resolution tools, HPET toggling, MSI-mode utilities, core-parking unparkers, CPU affinity/priority launchers.
- Mitigation and security changes: disabling Spectre/Meltdown mitigations, VBS/HVCI, Defender, SmartScreen, UAC, Windows Update, or Core Isolation.
- Service mass-disabling: SysMain/Superfetch, Windows Search, Print Spooler (unless no printer *and* the user asks), Xbox services, DiagTrack-as-performance, `svchost` split threshold changes.
- "Ultimate Performance"/custom imported power plans on Ryzen, and disabling Fast Startup or hibernation "for performance".
- Fullscreen-optimisation global disables, GameDVR registry deletion (use Settings), "disable mouse acceleration" presented as an FPS fix (it is a preference).
- RAM "cleaners", registry cleaners, prefetch/standby-list purgers, page file disabling, "debloat everything" presets.
- Visual-effects "best performance" on a modern GPU. Negligible gain, worse usability; mention only as a preference.

If the user insists on one of these, explain the risk and lack of evidence. They can apply it
themselves. The skill will not do it.

## Benchmarking advice

When the user wants proof, suggest a repeatable test: the same game scene or built-in benchmark,
three runs before and after, reporting average and 1 % lows, with a restart and no background
downloads before each set. Change one variable at a time.
