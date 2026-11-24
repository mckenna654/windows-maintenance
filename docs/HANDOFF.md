# Handoff

## Status (2026-11-24)

- First public release of the `windows-maintenance` Claude Code skill.
- The repo root is the skill: clone it to `%USERPROFILE%\.claude\skills\windows-maintenance`.
- Validated on Windows 11 25H2 with PowerShell 7.6 and 5.1 (parse checks on both; full runs on 7.6):
  - Read-only audit in all sections, as a standard user.
  - Clean: tier-1 dry run and execution, including an elevated run for admin targets.
  - Guards: protected paths, services and Appx packages are refused; running apps are skipped, never closed; tier-3 targets are refused without `-AllowTier3`.
  - `Invoke-Change.ps1` dry runs and `Compare-Audit.ps1` before-and-after report.

## Not yet verified

- `Invoke-Change.ps1 -Execute` for every action, and `Undo-Change.ps1 -Execute` (dry runs only so far).
- `New-RestorePoint.ps1` elevated (only the non-elevated refusal has been tested).
- Deep mode elevated (DISM analysis, CheckHealth, SMART counters).
- Full runs under Windows PowerShell 5.1.

## Known issues / next steps

- The npm-cache estimate uses the whole cache size, but `npm cache verify` only removes unreferenced data. Consider reporting it as an upper bound.
- DISM and pnputil parsing assumes English output.
