# Windows ISO Updater

> [!NOTE]
> This is a specialized companion to the main [Windows Fix-Up](https://github.com/brycefors/Windows-Fix-Up), [Windows Update Fix](https://github.com/brycefors/Windows-Fix-Up/tree/main/Windows-Update-Fix), and [Windows In-Place Upgrade](https://github.com/brycefors/Windows-Fix-Up/tree/main/Windows-InPlace-Upgrade) scripts. Instead of repairing an installed system, it builds **fresh, fully-patched installation media**: it downloads the latest official Microsoft ISO, integrates ("slipstreams") the latest cumulative update directly into the Windows images, and recompiles a brand-new bootable ISO that is already up to date.

This PowerShell script automates the whole process. A clean install or in-place upgrade started from the resulting ISO begins already patched, instead of spending a long time downloading and installing the same cumulative update after Setup finishes.

> [!TIP]
> **No PowerShell knowledge is required, just double-click `Run-Windows-ISO-Updater.bat`.** Everything is designed to run safely with its defaults: the batch file handles the UAC prompt and the execution policy for you (without changing any system-wide setting), the script explains what it is about to do and waits for your confirmation, and **nothing on the machine you run it from is modified**, because the build happens entirely against files in a working folder. Every file it fetches (the ISO, the updates, `oscdimg.exe`, and the Fido helper) is verified to come from an official Microsoft or GitHub source before it is used, as described in [Important Notes](#important-notes).

## Quick Start

1.  Put `Run-Windows-ISO-Updater.bat` and `Windows-ISO-Updater.ps1` in the same folder. (If the `.ps1` is missing, the batch file downloads it.)
2.  Double-click the batch file and accept the UAC prompt.
3.  Read the summary it prints and confirm.

Everything else is optional. For a specific edition, your own ISO, or a run with no prompts:

```shell
.\Run-Windows-ISO-Updater.bat -IsoPath "C:\ISOs\Win11.iso" -Edition "Windows 11 Pro" -Unattended
```

**Windows Server** media works too, with `-Server`. Server ISOs cannot be downloaded automatically, so
pass your own:

```shell
.\Run-Windows-ISO-Updater.bat -Server -IsoPath "C:\ISOs\Server2025.iso"
```

## Documentation

| Page | Contents |
|---|---|
| [Usage](docs/usage.md) | Running the script, command-line examples, Windows Server media, and slimming the ISO by removing editions. |
| [Command-Line Parameters](docs/parameters.md) | Every parameter and what it does. |
| [Scheduled Runs](docs/scheduled-runs.md) | Running this from a scheduled task: build stamps, skipping runs that would change nothing, and `-AutoClean` housekeeping. |
| [Unattended Installs](docs/unattended-installs.md) | `-UnattendPath`, plus two worked answer files: a no-OOBE lab machine and a sysprep gold image. |
| [Design Notes](docs/design-notes.md) | Why the already-patched check works the way it does, why both `boot.wim` indexes are serviced, and what Windows Update still offers afterwards. |
| [Reference](docs/reference.md) | Step by step of a run, how files are downloaded, disk space, output locations, and logging. |

## Important Notes

> [!WARNING]
> This is a **disk- and time-intensive** operation, and with the default parameters a full run normally takes **an hour or two**. The downloaded ISO, the extracted media, the mounted image, and the re-exported image all coexist during the build, and offline DISM servicing plus component-store cleanup can take a long time. Nothing on the machine running the script is changed, because all servicing happens against files in the working folder.

> [!TIP]
> **It is recommended to download the ISO yourself and pass it with `-IsoPath`.** The automatic download relies on the community Fido helper, which queries Microsoft's software-download servers on your behalf. Microsoft rate-limits and can temporarily block IP addresses that make repeated ISO requests. That shows up as *"Error: Sentinel marked this request as rejected"* or a *715-123130* error, which the script now prints verbatim (add `-Verbose` for Fido's full request log). The script automatically retries a few times with a growing delay (`-FidoRetryCount`, default 2 extra attempts), because the block is often transient. Downloading the ISO once from [microsoft.com/software-download](https://www.microsoft.com/software-download) (or with the Media Creation Tool) and reusing it with `-IsoPath` avoids this entirely.

> [!TIP]
> **If the link request stays blocked, the script can fall back to Microsoft's Media Creation Tool (`-UseMct`).** MCT talks to different Microsoft servers, so it usually still works when Fido is blocked. It is downloaded from Microsoft's official `go.microsoft.com` link and its **Authenticode signature is verified as validly signed by Microsoft** before it runs. Microsoft provides **no headless switch** for choosing ISO output or a save path, so this is *semi*-automated: the script launches MCT's ordinary wizard, then you pick the language/architecture, click "Create installation media" → "ISO file" and save it into the download folder. The script waits for MCT to close, picks up the new ISO automatically, and carries on. In an interactive run it offers this for you when Fido fails, and `-UseMct` skips Fido altogether.

> [!TIP]
> **You don't have to pass `-IsoPath` at all, you can just drop your ISO in the download folder.** If `-IsoPath` is not given, the script looks in the download folder (`<SystemDrive>\WISO-Work\Downloads` by default, or wherever `-DownloadPath` points) and reuses the **largest `.iso` file over 3 GB** it finds there instead of downloading one. This is the easiest route when double-clicking the batch file: create the folder, drop the ISO in, and run. It is also why a previously downloaded ISO is never re-downloaded. `-IsoPath` accepts a folder too and applies the same rule to it, but neither search is recursive, so the ISO has to sit directly in the folder.

- The Microsoft Update Catalog has **no public API**, so the script parses its search pages to find the latest cumulative update. If Microsoft changes the catalog layout the lookup may need adjustment, and you can always supply your own `.msu`/`.cab` packages with `-UpdatePath`.
- Recompiling the ISO requires **`oscdimg.exe`**, part of the **Windows ADK "Deployment Tools"** feature. If it is not already installed, the script downloads a **standalone `oscdimg.exe` (~140 KB) straight from Microsoft's public symbol server** ([how this works](https://pete.akeo.ie/2025/06/downloading-oscdimgexe-from-microsoft.html)) and caches it under `<WorkPath>\Tools`, so the multi-hundred-MB ADK is not needed. The download is verified against a pinned SHA-256. Use `-SkipOscdimgDownload` to disable this, and `-InstallAdk` to fall back to installing the ADK Deployment Tools instead.
- Every download URL (ISO, updates, oscdimg, ADK) is validated to point at an **official Microsoft host over HTTPS** before anything is downloaded.
- The **Fido helper is downloaded and executed**, so it is validated first: the URL must point at the official `github.com/pbatard/Fido` repository over HTTPS, and the downloaded script must be a plausible size, parse as PowerShell, carry Fido's header and `-GetUrl` parameter, and contain no code-execution, persistence or security-tampering commands (Fido is not code-signed, so there is no signature to verify). It is then run **in a separate PowerShell process** so it cannot touch this script's session. Its SHA-256 is logged on every run, and you can pin a version you have reviewed yourself with `-FidoSha256`.

> [!IMPORTANT]
> The working and download folders **must be on a local, fixed disk**. Cloud-synced folders (Google Drive, OneDrive, Dropbox, etc.) turn files into on-demand placeholders and sync them in the background, which makes DISM unable to read the `.msu`/`.wim` reliably. That shows up as *"An error occurred applying the Unattend.xml file from the .msu package"*. By default the script works and downloads under `<SystemDrive>\WISO-Work`, so if you run it from a cloud-synced folder, keep `-WorkPath`/`-DownloadPath` pointed at a local disk (and preferably pass your ISO with `-IsoPath` from a local copy).
>
> The same applies to network paths. A `-WorkPath` on a UNC share or a mapped drive is rejected outright, because DISM cannot mount and service images there. A **source ISO** on a network path is fine, it is copied to the download folder first, exactly like a cloud-synced one. Bear in mind that drive mappings are per-logon-session, so a mapped drive that works when you run the script by hand does not exist when the scheduled task runs. Use a UNC path rather than a drive letter for anything scheduled.

## Requirements

- **PowerShell 5.0+** and **Windows 10 / Server 2016** or newer, run **as Administrator**.
- An internet connection (unless you supply both the ISO with `-IsoPath` and updates with `-UpdatePath`).
- **`oscdimg.exe`**, downloaded automatically from Microsoft if it is not already present (or installed with the ADK via `-InstallAdk`).
- Plenty of free disk space on a **local** working drive, as covered in [Disk Space Requirements](docs/reference.md#disk-space-requirements).
