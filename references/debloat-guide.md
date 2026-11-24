# Debloat guide (gaming + development PC)

Goal: remove clutter and background noise the user doesn't use, without breaking
gaming, streaming, development or security. Expect tidiness and faster sign-in, not more FPS.
Say so honestly.

## Startup items

Classes from the audit:
- **protected:** gaming/streaming/security/sync/audio (Steam, AMD, OBS, Apollo/Sunshine, OneDrive, Realtek, SecurityHealth…). Never propose. Only disable if the user names it (`-AllowProtectedStartup`).
- **candidate:** matches `optionalStartupPatterns` (chat apps, extra launchers, Edge auto-launch, Adobe helpers, Docker Desktop, "optimizer" utilities, peripheral updaters). Propose with the reason.
- **review:** unknown. Identify it from the command path (vendor folder, exe name) and say what it does if you can tell. Typical review items on gaming PCs:
  - Peripheral software (Glorious Core, Logitech G HUB, Razer Synapse, Corsair iCUE, SteelSeries GG): applies DPI, macros or RGB at login. Keep if the user relies on profiles stored in software rather than on-device memory.
  - Monitor/system tools (DisplayFusion, Dell Display Manager, AudioSwitcher, Argus Monitor/fan control, Gigabyte Control Center): fan-control tools must stay. Ask about the rest.
  - Motherboard vendor updaters (e.g. Gigabyte SSD firmware task): low value at every login. Candidates once identified.
  - Game library frontends (Playnite): user preference.

Method: `Invoke-Change.ps1 -Action DisableStartup -Name "<exact name>" [-Source <source>]`.
It writes the `StartupApproved` flag, the same switch Task Manager uses, so the app can be
re-enabled in Task Manager or with `Undo-Change.ps1`. Run keys are never deleted. Scheduled
tasks are disabled, not deleted.

## Store (Appx) apps

- Candidates come from `appxCandidates` (based on Win11Debloat's default-selected consumer apps, minus anything gaming-related).
- Always protected: Store, Xbox app, Game Bar, Xbox Identity/TCUI/Speech overlays, Gaming Services, GameInput, codecs (HEVC/HEIF/AV1/VP9/WebP/Raw/Dolby), VCLibs/UI.Xaml/.NET/WindowsAppRuntime, AMD Radeon Software, Realtek/Dolby audio, Terminal, Notepad, Calculator, Photos, Snipping Tool, Paint, Edge, OneDrive, Windows Security, WSL.
- Removal is per-user (`Remove-AppxPackage`), not deprovisioning. Reinstall comes from the Store, or `Undo-Change.ps1` re-registers the package if its files remain.
- Show the notes ("keep if you use Phone Link") and let the user pick individually.

## Services

- Never set anything to **Disabled**. Only Automatic → **Manual**, so it still starts on demand.
- Windows services: only those in `optionalMicrosoftServices` (Fax, MapsBroker, RetailDemo, WMPNetworkSvc, DiagTrack). These are minor or privacy changes, not performance ones. For telemetry, prefer the supported Settings > Privacy & security > Diagnostics & feedback > *Required diagnostic data only*.
- Third-party auto services: propose Manual only when the user confirms they don't need that software running at boot. Common examples: Bonjour (iTunes/printer discovery leftovers), browser update services (keep, since they patch security), Mudfish/VPN launchers, TeraCopy, Power Automate. Keep anything for fan control, RGB the user wants, VPNs they rely on, backup agents, and all protected services.
- `SysMain`, `WSearch`, `DoSvc`, `BITS`, Xbox services, `AMD*` and anti-cheat are protected. Disabling them is a common "tweak" that hurts gaming or dev workflows.

## Desktop programs

- Flag: trialware, "PC optimizers", registry cleaners, driver updaters, toolbars, orphaned helpers (e.g. Bonjour without iTunes).
- Uninstall through Settings > Apps > Installed apps, or `winget uninstall --exact --id <Id>` after approval, one program at a time. Show `winget list --name "<name>"` first to get the Id.
- Never uninstall GPU drivers/software, chipset, audio, peripheral or fan-control software, runtimes (VC++ redists, .NET, DirectX, Java), game launchers or anti-cheat unless the user specifically asks.

## What not to do (and why)

- Do not remove Edge, WebView2 or OneDrive via forced scripts. They break Widgets, Teams, Store and Office features. Use Settings if the user wants OneDrive gone.
- Do not remove Xbox components "because I use Steam". Game Pass, Store games, controllers (GIP), Game Bar and AMD X3D core parking depend on them.
- Do not apply blanket "Disable telemetry/Copilot/Recall" registry packs. Use the documented Settings toggles. Recall is opt-in and off unless enabled.
