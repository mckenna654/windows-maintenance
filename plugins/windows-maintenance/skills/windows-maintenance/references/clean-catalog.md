# Cleanup catalog

Source of truth: `config/clean-targets.json`. This file explains the reasoning so you can
describe each target to the user.

## Tiers

- **Tier 1:** regenerates automatically with negligible cost. Offer as a group.
- **Tier 2:** regenerates, but has a cost: re-download, shader recompilation stutter, lost crash evidence, slow DISM run, or signed-out web views. Explain the cost per item.
- **Tier 3:** user data, or report-only. Never part of a group approval.

## Targets

| Id | Tier | Admin | What / why it's safe | Cost or caveat |
|---|---|---|---|---|
| user-temp | 1 | no | `%TEMP%` files untouched 3+ days | Skips Claude scratch, locked files |
| windows-temp | 1 | yes | `C:\Windows\Temp` 3+ days | none |
| user-wer / system-wer | 1 | no/yes | Windows Error Reporting queues/archives 7+ days | Lose old crash reports |
| user-crashdumps | 1 | no | `%LOCALAPPDATA%\CrashDumps` 14+ days | Keep if debugging an app crash |
| inetcache | 1 | no | Legacy WinINet cache | none |
| edge/chrome/brave/firefox-cache | 1 | no | `Cache`, `Code Cache`, `GPUCache` per profile | Browser must be closed; pages reload once. Never cookies, logins, history, extensions |
| discord-cache | 1 | no | Discord HTTP/code/GPU cache | Discord must be closed |
| vscode-cache | 1 | no | VS Code caches/logs 7+ days | Settings/extensions untouched |
| steam-logs | 1 | no | Steam `logs`, `dumps` 14+ days | none |
| epic-webcache | 1 | no | Epic launcher web cache/logs | Launcher must be closed |
| delivery-optimization | 1 | yes | `Delete-DeliveryOptimizationCache` | Peers can't fetch from you; DO stays on |
| npm/pip/uv/pnpm/nuget/go | 1 | no | Tool-native cache GC commands | Re-downloads only what's needed |
| gpu-shader-cache | 2 | no | AMD DxCache/DxcCache/VkCache/GLCache, D3DSCache, NVIDIA/Intel | Games recompile shaders, causing stutter on first runs. Only after driver change/corruption. Adrenalin's "Reset Shader Cache" is equivalent |
| steam-htmlcache | 2 | no | Steam CEF web cache | Store/community web views reload, may need sign-in |
| amd/nvidia-installer-leftovers | 2 | yes | `C:\AMD`, `C:\NVIDIA` extraction folders 14+ days | Lose offline reinstall copy |
| component-store | 2 | yes | `DISM /StartComponentCleanup` (no `/ResetBase`) | 5–30 min; updates stay uninstallable |
| yarn-cache, docker-build-cache | 2 | no | Full cache clean / build cache prune | Re-downloads / rebuilds |
| minidumps, memory-dmp, live-kernel-reports | 2 | yes | BSOD/TDR evidence | Destroys diagnostic evidence. Check audit health first |
| recycle-bin | 3 | no | User's deleted files | Permanent. Needs `-AllowTier3` + explicit yes |
| windows-old | 3 | — | Report only → Settings > Storage > Temporary files | Ends rollback of last feature update |
| windows-update-cleanup | 3 | — | Report only → Settings > Storage > Temporary files | — |
| hiberfil, pagefile | 3 | — | Report only, never touched | — |

## Review-only (listed by the audit, never cleaned by script)

- **node_modules / build outputs** in dev roots (Deep mode or `-DevRoots`). The user deletes per project. `npm ci`/`pnpm install` restores them.
- **WSL / Docker VHDX** growth. Prune inside first (`docker system df`, then a specific prune the user approves), then compact via Docker Desktop (Troubleshoot > Clean/Purge data) or `wsl --manage <distro> --set-sparse true` (WSL 2.x). Never `docker system prune -a --volumes` without listing what it removes.
- **Downloads, Videos and large personal files:** suggest the user sorts them, or point to Settings > System > Storage > Cleanup recommendations.
- **Old display-driver packages** (`pnputil /enum-drivers /class Display`). Manual review only.
- **Maven `.m2`, Gradle caches, cargo registry:** large but expensive to rebuild. Mention only.

## Measurement notes

- Estimates are logical sizes of files passing the age filter and exclusions. Real recovery is lower when files are locked.
- `measurement incomplete (needs admin)` means system folders couldn't be read. Re-run the audit elevated for exact figures.
- The clean result records both the sum of deleted file sizes and the drive free-space delta. Report both. They differ because of concurrent writes, compression and cluster slack.
