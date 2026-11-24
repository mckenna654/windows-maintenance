# Safety policy

The skill's safety does not depend on Claude remembering rules: the scripts enforce them.
This file explains what they enforce, so you can explain refusals to the user.

## Layers of protection

| Layer | Where | What it does |
|---|---|---|
| Read-only audit | `Invoke-Audit.ps1` | Only reads. Its only writes are report files in `%LOCALAPPDATA%\WindowsMaintenance\reports`. |
| Dry run by default | `Invoke-Clean.ps1`, `Invoke-Change.ps1`, `Undo-Change.ps1` | Nothing changes without `-Execute`. |
| Allow-list | `config/clean-targets.json` | Only catalog ids can be cleaned. Arbitrary paths are impossible. |
| Deny-list | `config/protected.json` → `Test-WMCleanRoot` | Refuses a root that is inside or contains a protected location, or is a drive root, profile root, AppData root, Windows or Program Files. |
| Walker guards | `WinMaint.Fs` (C#) | Never follows junctions/symlinks. Skips excluded names (`.git`, `saves`, `userdata`, `steamapps`, `Cookies`, `Login Data`, `Local Storage`, `IndexedDB`, `Extensions`, `claude`, …) and key/save file extensions. Deletes only files older than the target's age. Skips locked files. Never deletes the root folder. |
| Process guard | `requiresClosed` | Skips a target while its owning app runs. Never kills it. |
| Tiering | `tier` | Tier 3 needs `-AllowTier3`. Report-only targets cannot be executed. |
| Protected services, Appx, startup | `protected.json` patterns | Refused with no override. The single exception: a protected *startup entry* can be disabled with `-AllowProtectedStartup` when the user names it, because that is reversible and breaks nothing. |
| Windows services | `Invoke-Change.ps1` | Windows (`\Windows\`/svchost) services can only be changed if listed in `optionalMicrosoftServices`. Changes are only Automatic → Manual, never Disabled. |
| Journal | `journal.jsonl` | Every change records its previous state. `Undo-Change.ps1` reverses it. |
| Backups | `Backup-State.ps1`, `New-RestorePoint.ps1` | Config export before changes. Restore point before system-level changes. |

## Protected data (never deleted or modified)

- **Personal files:** Documents, Desktop, Pictures, Videos, Music, Downloads, Favorites, Saved Games, OneDrive.
- **Game saves and libraries:** `Saved Games`, `Documents\My Games`, Steam `userdata`/`steamapps`/`config`, `XboxGames`, `WindowsApps`, Epic manifests. Any folder named `save(s)`/`SaveGames` anywhere.
- **Development:** `source`, `Projects`, `repos`, `dev`, `code`, `Documents\Claude Code`; any `.git`. node_modules/build outputs are review-only.
- **Credentials and keys:** `.ssh`, `.gnupg`, `.aws`, `.azure`, `.kube`, `.docker`, `.git-credentials`, `.npmrc`, `.netrc`, DPAPI `Protect`, Credential Manager `Credentials`/`Vault`, certificate stores. Browser `Login Data`, `Cookies`, `Local Storage`, `IndexedDB`, `Session Storage`, `Sync Data`, `Extensions`.
- **App settings and agent state:** `%LOCALAPPDATA%\Packages`, `.claude`, `.codex`, `.vscode`, `.config`, `.m2`, and Claude Desktop data. Only named cache subfolders are ever cleaned.
- **System:** WinSxS (DISM only), `Installer`, `System32`, `DriverStore`, `Prefetch`, event logs, restore points, page file, hibernation file.

## Protected functionality

| Area | Protected items |
|---|---|
| Steam | client, Steam Client Service, steamwebhelper, userdata, libraries, shader caches |
| Xbox / Game Pass | Xbox app (`Microsoft.GamingApp`), Gaming Services, Xbox Identity Provider, Game Bar (`XboxGamingOverlay`: also needed for AMD X3D core parking), Xbox Live auth/save/net/accessory services, GameInput, Store, ClipSVC, LicenseManager, InstallService, Delivery Optimization service, wlidsvc, TokenBroker |
| AMD | Adrenalin (`AMDRadeonSoftware` Appx, `RadeonSoftware`, `AMDRSServ`, CNext tasks StartCN/StartDVR), AMD services (`AMD*`, `amd*` including `amd3dvcacheSvc`, `AmdPpkgSvc`), noise suppression |
| Streaming | Moonlight, Sunshine, Apollo, Parsec, OBS, Streamlabs, virtual display drivers, Tailscale, ZeroTier |
| Anti-cheat | EasyAntiCheat(+EOS), BattlEye (`BEService`/`BEDaisy`), Riot Vanguard (`vgc`/`vgk`/`vgtray`), FACEIT, EA AntiCheat, PunkBuster, ESEA, nProtect, XIGNCODE (`xhunter1`), mhyprot, Denuvo |
| Security | Defender (all components), Security Center, Firewall/BFE, SmartScreen, UAC, Secure Boot, TPM, BitLocker, VBS/HVCI, Windows Update stack, CryptSvc, KeyIso, VaultSvc |

## When a script refuses

Explain the refusal in plain words and offer the safe alternative (Settings page, vendor
app, manual step). Never edit `protected.json`, rename items, call the underlying cmdlet
directly, or chain other tools to get around a refusal. If the user still wants it, they
can do it themselves; explain the risk.
