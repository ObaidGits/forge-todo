# Windows installer (Inno Setup)

`forge.iss` packages the Flutter Windows release output into a single per-user
installer, `Forge-<version>-windows-setup.exe`.

## What it does

- Packages the **entire** `build\windows\x64\runner\Release\` folder
  (`forge.exe`, `flutter_windows.dll`, `data\`, and plugin DLLs).
- Installs **per-user** (`PrivilegesRequired=lowest`) — no administrator rights.
- Creates a Start-menu shortcut and an **optional** desktop shortcut.
- Bundles `vc_redist.x64.exe` (Microsoft Visual C++ 2015–2022 x64 runtime) and
  runs it **silently** (`/install /quiet /norestart`) on install so the app's
  runtime dependency is always present.
- Uses the app version and `app.forge.forge` / `Forge contributors` metadata.

## Building locally

Requires [Inno Setup 6](https://jrsoftware.org/isdl.php) (`iscc` on `PATH`).

```powershell
flutter build windows --release
# Download the VC++ redistributable next to the script (optional locally):
Invoke-WebRequest https://aka.ms/vs/17/release/vc_redist.x64.exe -OutFile packaging\windows\vc_redist.x64.exe
iscc /DAppVersion=0.1.0 packaging\windows\forge.iss
```

The compiled installer is written to `packaging\windows\Forge-0.1.0-windows-setup.exe`.

If `vc_redist.x64.exe` is not downloaded, the script still compiles and installs
the app (the redistributable step is skipped via `skipifsourcedoesntexist` /
the `VcRedistBundled` check).

## CI

`.github/workflows/github-release.yml` installs Inno Setup via Chocolatey,
downloads `vc_redist.x64.exe` into this folder, then runs
`iscc /DAppVersion=<pubspec version> packaging\windows\forge.iss` and uploads
the resulting setup `.exe`.

> The Windows installer is validated on CI only — it cannot be compiled on
> Linux. The script is authored to Inno Setup 6 syntax.
