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

## Not yet verified

- `Invoke-Change.ps1 -Execute` for every action, and `Undo-Change.ps1 -Execute` (dry runs only so far).
- `New-RestorePoint.ps1` elevated; Deep mode elevated; full runs under Windows PowerShell 5.1.
- An end-to-end auto-update after a push (the mechanism follows the Claude Code docs; not yet observed).

## Known issues / next steps

- The npm-cache estimate uses the whole cache size, but `npm cache verify` only removes unreferenced data. Consider reporting it as an upper bound.
- DISM and pnputil parsing assumes English output.
- Optional: add a 512 px+ PNG icon at `plugins/windows-maintenance/.claude-plugin/icon.png` if the plugin is ever submitted to the official directory.
