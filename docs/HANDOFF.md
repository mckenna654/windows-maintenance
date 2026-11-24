# Handoff

## Status (2026-11-24)

- The repo is a Claude Code **plugin marketplace** (`.claude-plugin/marketplace.json`) containing one plugin, `windows-maintenance`. The skill lives at `plugins/windows-maintenance/skills/windows-maintenance/`.
- Install: `claude plugin marketplace add mckenna654/windows-maintenance`, then `claude plugin install windows-maintenance@windows-maintenance`. Command: `/windows-maintenance:windows-maintenance`.
- Versioning: `plugin.json` and `marketplace.json` deliberately have **no `version`**, so the commit SHA is the version and every push to `main` reaches users who have auto-update on. `claude plugin validate` warns about this; the warning is intentional. If you add a `version` later, bump it on every release (in one file only).
- `SKILL.md` no longer hard-codes its install path. It uses the "Base directory for this skill" path that Claude Code provides when the skill loads.
- Working copy on Jake's PC: `C:\Users\jake\Documents\Claude Code\windows-maintenance`. The old personal-skill clone in `~/.claude/skills` was replaced by the plugin install, with auto-update on via `extraKnownMarketplaces` in user settings.

## Verified

- Windows 11 25H2, PowerShell 7.6 and 5.1 (parse checks on both; full runs on 7.6):
  - Read-only audit in all sections.
  - Tier-1 clean, dry run and execution, including an elevated run for admin targets.
  - Guards: protected paths, services and Appx packages are refused; running apps are skipped; tier-3 targets are refused without `-AllowTier3`.
  - Before-and-after report.
- `claude plugin validate` passes (warnings only: no version by design, no listing icon).

- Real changes (2026-11-24): `SetPowerPlan`, and `DisableStartup` for HKCU-Run, HKLM-Run and a scheduled task. Values were checked in the registry and re-read correctly by the audit after fix dd8ffc1.
- `New-RestorePoint.ps1` elevated, on the "Windows skipped: a restore point under 24 h old already exists" path.
- `claude plugin marketplace update` + `claude plugin update` pulled a new commit into the installed plugin.

- Real changes (Group B): `SetServiceManual` on a third-party service (Bonjour), and `RemoveAppx` for Mail & Calendar, Dev Home and People.
- Restore points: Windows did create one, but the original script checked the list immediately and wrongly reported "skipped". The script now polls for up to 90 s for a new sequence number.

## Not yet verified

- `SetGameMode` and `EnableStartup` with `-Execute`; `Undo-Change.ps1 -Execute`.
- The fixed `New-RestorePoint.ps1` polling path, which can only be tested more than 24 h after the last restore point (2026-11-24 22:17). Deep mode elevated; full runs under Windows PowerShell 5.1.
- Background auto-update arriving on its own after a push (only the manual update command has been run).

## Known issues / next steps

- The npm-cache estimate uses the whole cache size, but `npm cache verify` only removes unreferenced data. Consider reporting it as an upper bound.
- DISM and pnputil parsing assumes English output.
- Optional: add a 512 px+ PNG icon at `plugins/windows-maintenance/.claude-plugin/icon.png` if the plugin is ever submitted to the official directory.
