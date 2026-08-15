# Windows ISO Updater

> [!NOTE]
> This is a specialized companion to the main [Windows Fix-Up](https://github.com/brycefors/Windows-Fix-Up), [Windows Update Fix](https://github.com/brycefors/Windows-Fix-Up/tree/main/Windows-Update-Fix), and [Windows In-Place Upgrade](https://github.com/brycefors/Windows-Fix-Up/tree/main/Windows-InPlace-Upgrade) scripts. Instead of repairing an installed system, it builds **fresh, fully-patched installation media**: it downloads the latest official Microsoft ISO, integrates ("slipstreams") the latest cumulative update directly into the Windows images, and recompiles a brand-new bootable ISO that is already up to date.

This PowerShell script automates the whole process. A clean install or in-place upgrade started from the resulting ISO begins already patched, instead of spending a long time downloading and installing the same cumulative update after Setup finishes.

> [!TIP]
> **No PowerShell knowledge is required — just double-click `Run-Windows-ISO-Updater.bat`.** Everything is designed to run safely with its defaults: the batch file handles the UAC prompt and the execution policy for you (without changing any system-wide setting), the script explains what it is about to do and waits for your confirmation, and **nothing on the machine you run it from is modified** — the build happens entirely against files in a working folder. Every file it fetches (the ISO, the updates, `oscdimg.exe`, and the Fido helper) is verified to come from an official Microsoft or GitHub source before it is used — see [Important Notes](#important-notes).

## Table of Contents

- [Important Notes](#important-notes)
- [Requirements](#requirements)
- [How to Run This Script](#how-to-run-this-script)
  - [Recommended Method: Using the Batch File](#recommended-method-using-the-batch-file)
  - [Running with Parameters (from Command Line)](#running-with-parameters-from-command-line)
- [Command-Line Parameters](#command-line-parameters)
- [Unattended Installs](#unattended-installs)
- [What the Script Does](#what-the-script-does)
- [How Files Are Downloaded](#how-files-are-downloaded)
- [Design Notes](#design-notes)
  - [Why Updates Are Not Pre-Checked Against the ISO](#why-updates-are-not-pre-checked-against-the-iso)
- [Disk Space Requirements](#disk-space-requirements)
- [Where Files Are Written](#where-files-are-written)
- [Logging](#logging)

## Important Notes

> [!WARNING]
> This is a **disk- and time-intensive** operation. The downloaded ISO, the extracted media, the mounted image, and the re-exported image all coexist during the build, and offline DISM servicing plus component-store cleanup can take a long time. Nothing on the machine running the script is changed — all servicing happens against files in the working folder.

> [!TIP]
> **It is recommended to download the ISO yourself and pass it with `-IsoPath`.** The automatic download relies on the community Fido helper, which queries Microsoft's software-download servers on your behalf. Microsoft rate-limits and can temporarily block IP addresses that make repeated ISO requests — this shows up as *"Error: Sentinel marked this request as rejected"* or a *715-123130* error, which the script now prints verbatim (add `-Verbose` for Fido's full request log). The script automatically retries a few times with a growing delay (`-FidoRetryCount`, default 2 extra attempts), because the block is often transient. Downloading the ISO once from [microsoft.com/software-download](https://www.microsoft.com/software-download) (or with the Media Creation Tool) and reusing it with `-IsoPath` avoids this entirely.

> [!TIP]
> **If the link request stays blocked, the script can fall back to Microsoft's Media Creation Tool (`-UseMct`).** MCT talks to different Microsoft servers, so it usually still works when Fido is blocked. It is downloaded from Microsoft's official `go.microsoft.com` link and its **Authenticode signature is verified as validly signed by Microsoft** before it runs. Microsoft provides **no headless switch** for choosing ISO output or a save path, so this is *semi*-automated: the script launches MCT with the version, architecture, language and edition already selected (`-MctEdition`, `-MctLangCode`), then you click "Create installation media" → "ISO file" and save it into the download folder. The script waits for MCT to close, picks up the new ISO automatically, and carries on. In an interactive run it offers this for you when Fido fails; pass `-UseMct` to skip Fido altogether.

> [!TIP]
> **You don't have to pass `-IsoPath` at all — you can just drop your ISO in the download folder.** If `-IsoPath` is not given, the script looks in the download folder (`<SystemDrive>\WISO-Work\Downloads` by default, or wherever `-DownloadPath` points) and reuses the **largest `.iso` file over 3 GB** it finds there instead of downloading one. This is the easiest route when double-clicking the batch file: create the folder, drop the ISO in, and run. It is also why a previously downloaded ISO is never re-downloaded.

- The Microsoft Update Catalog has **no public API**, so the script parses its search pages to find the latest cumulative update. If Microsoft changes the catalog layout the lookup may need adjustment; you can always supply your own `.msu`/`.cab` packages with `-UpdatePath`.- Recompiling the ISO requires **`oscdimg.exe`**, part of the **Windows ADK "Deployment Tools"** feature. If it is not already installed, the script downloads a **standalone `oscdimg.exe` (~140 KB) straight from Microsoft's public symbol server** ([how this works](https://pete.akeo.ie/2025/06/downloading-oscdimgexe-from-microsoft.html)) and caches it under `<WorkPath>\Tools`, so the multi-hundred-MB ADK is not needed. The download is verified against a pinned SHA-256. Use `-SkipOscdimgDownload` to disable this, and `-InstallAdk` to fall back to installing the ADK Deployment Tools instead.
- Every download URL (ISO, updates, oscdimg, ADK) is validated to point at an **official Microsoft host over HTTPS** before anything is downloaded.
- The **Fido helper is downloaded and executed**, so it is validated first: the URL must point at the official `github.com/pbatard/Fido` repository over HTTPS, and the downloaded script must be a plausible size, parse as PowerShell, carry Fido's header and `-GetUrl` parameter, and contain no code-execution, persistence or security-tampering commands (Fido is not code-signed, so there is no signature to verify). It is then run **in a separate PowerShell process** so it cannot touch this script's session. Its SHA-256 is logged on every run, and you can pin a version you have reviewed yourself with `-FidoSha256`.

> [!IMPORTANT]
> The working and download folders **must be on a local, fixed disk**. Cloud-synced folders (Google Drive, OneDrive, Dropbox, etc.) turn files into on-demand placeholders and sync them in the background, which makes DISM unable to read the `.msu`/`.wim` reliably — this shows up as *"An error occurred applying the Unattend.xml file from the .msu package"*. By default the script works and downloads under `<SystemDrive>\WISO-Work`; if you run it from a cloud-synced folder, keep `-WorkPath`/`-DownloadPath` pointed at a local disk (and preferably pass your ISO with `-IsoPath` from a local copy).

## Requirements

- **PowerShell 5.0+** and **Windows 10 / Server 2016** or newer, run **as Administrator**.
- An internet connection (unless you supply both the ISO with `-IsoPath` and updates with `-UpdatePath`).
- **`oscdimg.exe`** — downloaded automatically from Microsoft if it is not already present (or installed with the ADK via `-InstallAdk`).
- Plenty of free disk space on a **local** working drive — see [Disk Space Requirements](#disk-space-requirements).

## How to Run This Script

The easiest and recommended way to run this script is by using the `Run-Windows-ISO-Updater.bat` file. It automatically handles administrator elevation and PowerShell execution policies, and will download the latest `Windows-ISO-Updater.ps1` from GitHub if it is missing.

**As long as you use the batch file, no setup or PowerShell experience is needed.** It requests administrator rights through the normal UAC prompt, downloads the script over HTTPS from the official [Windows-ISO-Updater](https://github.com/brycefors/Windows-ISO-Updater) repository if it is not already next to it, and runs it with `-ExecutionPolicy Bypass` scoped to that single run — your system-wide execution policy is never changed. Running the `.ps1` by hand works too, but then elevation and execution policy are on you.

### Recommended Method: Using the Batch File

1.  **Download Files:** Make sure both `Run-Windows-ISO-Updater.bat` and `Windows-ISO-Updater.ps1` are saved in the **same folder**. (If the `.ps1` is missing, the batch file will download it automatically.)
2.  **Run the Batch File:** Double-click the `Run-Windows-ISO-Updater.bat` file.
3.  **Administrator Prompt:** A User Account Control (UAC) window will appear asking for administrative privileges. Click **Yes**.
4.  **Follow Prompts:** The script opens in a new window, summarizes what it will do, and asks for confirmation before downloading and building.

### Running with Parameters (from Command Line)

To use command-line parameters, run the batch file from a Command Prompt or PowerShell terminal.

1.  Open Command Prompt or PowerShell.
2.  Navigate to the directory where you saved the files (e.g., `cd C:\Users\YourUser\Downloads`).
3.  Run the batch file with your desired parameters. For example:
    ```shell
    .\Run-Windows-ISO-Updater.bat -Unattended -InstallAdk -Edition "Windows 11 Pro"
    ```

### Removing Editions (Slimming the ISO)

A Windows ISO's `install.wim` usually contains many editions (Home, Home N, Pro, Education, etc.). **By default the script keeps only the highest edition present** (e.g. Enterprise over Pro, or Pro over Home) and removes the rest — this speeds up servicing and produces a smaller ISO. Use `-KeepAllEditions` to keep every edition, or `-KeepEditions` to choose exactly which ones to keep.

```shell
:: See what editions are inside the ISO first (downloads/uses the ISO, then just lists and exits)
.\Run-Windows-ISO-Updater.bat -ListEditions

:: Keep EVERY edition instead of just the highest one
.\Run-Windows-ISO-Updater.bat -KeepAllEditions

:: Build an updated ISO containing ONLY Windows 11 Pro and Home (by name)
.\Run-Windows-ISO-Updater.bat -KeepEditions "Windows 11 Pro","Windows 11 Home"

:: Same idea, selecting by index number instead of name
.\Run-Windows-ISO-Updater.bat -KeepEditions 6,1
```

`-KeepEditions` accepts edition names (partial matches allowed) or index numbers, and overrides the highest-edition default. Only the kept editions are serviced and re-exported, so the removed editions are gone from the final `install.wim`. It works with `-SkipUpdates` too, if you only want to trim editions without integrating updates.

## Command-Line Parameters

The script supports the following optional parameters:

| Parameter | Description |
|---|---|
| `-Unattended` | Runs the script without any confirmation prompts. |
| `-IsoPath` | Path to an existing Windows ISO to update instead of downloading one from Microsoft. Omit it and the script reuses the largest `.iso` over 3 GB found in the download folder. |
| `-WindowsVersion` | Windows version to download/update: `10` or `11`. Defaults to `11`. |
| `-Release` | Fido release to request (e.g. `24H2`, `23H2`) or `Latest`. Defaults to `Latest`. |
| `-Language` | ISO language as named by Microsoft/Fido (e.g. `English`, `"English International"`). Defaults to `English`. |
| `-Edition` | Which edition inside `install.wim` to service: `All` (default) or an edition name like `"Windows 11 Pro"`. |
| `-KeepEditions` | Editions to **keep** in the final ISO, removing the rest to slim it down. Accepts edition names (partial matches allowed) or index numbers, comma-separated. Overrides the default of keeping only the highest edition. |
| `-KeepAllEditions` | Keep **every** edition in the final ISO. By default only the highest edition present (e.g. Enterprise over Pro, or Pro over Home) is kept. |
| `-ListEditions` | List the editions/indexes inside the ISO's `install.wim` and exit, without downloading updates or building anything. Useful for choosing `-Edition`/`-KeepEditions` values. |
| `-UpdatePath` | Folder containing your own `.msu`/`.cab` update packages to integrate instead of fetching from the Microsoft Update Catalog. |
| `-SkipDotNet` | Skip the **.NET cumulative update**. The .NET update is downloaded and integrated **by default**; use this switch to leave it out. |
| `-SkipSetupDU` | Skip the **Setup Dynamic Update**, which refreshes the loose Windows Setup files in the media's `sources` folder. It is applied **by default**; without it the Windows 11 24H2+ Setup engine can fail with *"Windows 11 installation has failed"*. |
| `-ServiceWinRE` | Also service the recovery image (`winre.wim`). Off by default; the Safe OS Dynamic Update is used when available. |
| `-SkipUpdates` | Skip update integration entirely and just extract and recompile the ISO. |
| `-CompressEsd` | Export the finished image as `install.esd` (LZMS "recovery" compression) instead of `install.wim`. Typically **25-40% smaller**, which can bring the image under the 4 GB FAT32 limit for UEFI USB sticks — but the export is slow and the finished media cannot be serviced again without converting it back. |
| `-UnattendPath` | Path to an unattended answer file to place on the finished ISO as `\autounattend.xml`, so Windows Setup runs without prompting. |
| `-DownloadPath` | Directory to download the ISO/updates into. Defaults to the script folder. |
| `-WorkPath` | Working folder used to extract and service the media. Defaults to `<SystemDrive>\WISO-Work`. |
| `-OutputIsoPath` | Full path for the recompiled ISO. Defaults to the download folder with an `-Updated` suffix. |
| `-OscdimgPath` | Full path to `oscdimg.exe` if the Windows ADK is installed in a non-standard location. |
| `-SkipOscdimgDownload` | Do not download a standalone `oscdimg.exe` from Microsoft's symbol server; require the Windows ADK instead. |
| `-InstallAdk` | If `oscdimg.exe` is not found and cannot be downloaded, download and silently install the ADK Deployment Tools from Microsoft. |
| `-FidoUrl` | Override the URL used to fetch the Fido download helper. Must still point at the official `github.com/pbatard/Fido` repository. |
| `-FidoSha256` | Pin the expected SHA-256 of `Fido.ps1` so only that reviewed version is ever run. |
| `-FidoRetryCount` | Extra attempts to make when Fido cannot resolve a download link (Microsoft's anti-bot check is often transient). Defaults to `2`; `0` disables retrying. |
| `-UseMct` | Skip Fido and get the ISO with Microsoft's Media Creation Tool instead. MCT has no headless mode, so you click through its last few pages and save the ISO into the download folder. |
| `-MctUrl` | Override the URL used to download the Media Creation Tool. Must still be an official Microsoft URL. |
| `-MctEdition` | Edition passed to MCT's `/MediaEdition` switch (e.g. `Professional`, `Enterprise`, `Education`). Defaults to `Professional`. |
| `-MctLangCode` | Locale code passed to MCT's `/MediaLangCode` switch (e.g. `en-US`). Derived from `-Language` when not set. |
| `-AdkSetupUrl` | Override the URL used to download the Windows ADK setup bootstrapper. |
| `-OscdimgUrl` | Override the Microsoft symbol server URL used to download the standalone `oscdimg.exe`. |
| `-OscdimgSha256` | Expected SHA-256 of the downloaded `oscdimg.exe`. Pass an empty string to skip the hash check when overriding `-OscdimgUrl`. |
| `-LogPath` | Directory to write log files to. Defaults to a `Logs` folder inside the working folder. |
| `-SkipInteractive` | Skips the interactive confirmation prompt (still shows output). |

## Unattended Installs

Pass an answer file with `-UnattendPath` and it is copied to the root of the finished ISO as `autounattend.xml`:

```shell
.\Run-Windows-ISO-Updater.bat -UnattendPath "C:\Answer\autounattend.xml"
```

Windows Setup implicitly reads `\autounattend.xml` from the root of read-only boot media during the `windowsPE` pass, so nothing else is needed — boot the ISO and Setup runs without prompting. Generate the file with [Windows System Image Manager](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/wsim/windows-system-image-manager-technical-reference) (part of the ADK) or a generator such as [schneegans.de/windows/unattend-generator](https://schneegans.de/windows/unattend-generator/).

The script validates that the file exists and is well-formed XML before starting the build, and warns if the root element is not `<unattend>`.

### Example: lab machine with no OOBE

[`Examples/autounattend-lab-admin.xml`](Examples/autounattend-lab-admin.xml) skips OOBE entirely, signs in automatically as the built-in Administrator (password `Password123`), enables Remote Desktop, and sets `PreventDeviceEncryption` **only when the install detects it is running in a virtual machine**, so Windows 11 24H2 does not silently turn on BitLocker there. Physical machines built from the same ISO encrypt as normal. On VMware guests it also installs VMware Tools at first logon, using a Tools ISO mounted by the hypervisor if one is present and downloading from `packages.vmware.com` otherwise.

The file was produced with [schneegans.de/windows/unattend-generator](https://schneegans.de/windows/unattend-generator/) and then **hand edited**; a comment at the top of the file records exactly what was changed and why. The generator URL preserved alongside it reproduces the original options only — regenerating from it discards the manual changes.

```shell
.\Run-Windows-ISO-Updater.bat -UnattendPath ".\Examples\autounattend-lab-admin.xml"
```

> [!CAUTION]
> That example produces a deliberately insecure machine: a well-known Administrator password stored in plain text in the answer file and on the finished ISO, an automatic first sign-in as Administrator, Remote Desktop reachable on all firewall profiles, and a first boot that downloads and silently runs an installer from the internet. It is for throwaway VMs on a trusted network only — change the password in both places in the file, and never reuse it anywhere that matters.

> [!WARNING]
> **This example partitions and formats disk 0 without asking which disk to use.** A generated WinPE script first asserts that disk 0 exists and is between 100 and 4000 GiB, aborting if not. If disk 0 is **empty it proceeds with no prompt at all** — clean, partition, apply image index 1, reboot. If disk 0 **already holds partitions** it stops and asks: you must type `WIPE` to erase it, and any other answer aborts without touching the disk.
>
> Because it applies **index 1**, it pairs with the default edition handling, which leaves a single edition at index 1. If you build with `-KeepAllEditions`, index 1 is whichever edition came first in the original ISO — usually Home, not the one you probably want.

> [!WARNING]
> Two things to watch for:
> - **Edition selection.** By default this script keeps only the highest edition and renumbers `install.wim`, so an answer file that selects the edition with `/IMAGE/INDEX` will point at the wrong image. Use `/IMAGE/NAME` instead, or build with `-KeepAllEditions`. The script warns when it detects this combination.
> - **Secrets.** Answer files store passwords in plain text or base64 and product keys in the clear. Anyone who can read the ISO can recover them, so treat the finished ISO as a secret and don't commit the answer file to source control.

## What the Script Does

1.  **Locate `oscdimg.exe`** — Downloads a standalone copy from Microsoft's symbol server if it is not already installed (or installs the ADK with `-InstallAdk`), and otherwise fails fast so the build cannot get most of the way through and then be unable to recompile the ISO.
2.  **Obtain the ISO** — Uses `-IsoPath` if given, otherwise reuses the largest `.iso` over 3 GB already sitting in the download folder, and only if neither is available downloads the matching official Microsoft ISO via the community [Fido](https://github.com/pbatard/Fido) helper (verified and sandboxed in its own process — see [Important Notes](#important-notes)). Blocked link requests are retried with a growing delay, and Microsoft's signature-verified Media Creation Tool can be used as a guided fallback (`-UseMct`).
3.  **Extract the ISO** — Mounts the ISO and mirrors its contents into the working folder with `robocopy`, then dismounts. If the media ships `install.esd`, it is converted to an editable `install.wim`.
4.  **Find the updates** — Detects the feature update (e.g. `24H2`) and architecture from the image, then downloads the latest combined Servicing Stack + Cumulative Update (and, by default, the .NET cumulative update — disable with `-SkipDotNet`, and the Setup Dynamic Update — disable with `-SkipSetupDU`) from the Microsoft Update Catalog. `-UpdatePath` uses your own packages instead.
5.  **Integrate the updates** — Uses offline DISM to apply the package(s) to `install.wim` (by default only the highest edition present — override with `-KeepAllEditions` or `-KeepEditions`/`-Edition`), to `boot.wim` (Windows Setup / WinPE), and optionally to `winre.wim`.
6.  **Refresh the media Setup files** — Expands the **Setup Dynamic Update** over the media's `sources` folder (updated Setup binaries, compatibility database and replacement component manifests), then copies the serviced `setup.exe`, `setuphost.exe` (Windows 11 24H2+) and boot manager files out of `boot.wim` index 2 onto the media. Windows Setup **fails during installation** if these loose files do not match the version inside `boot.wim`.
7.  **Clean up and shrink** — Runs `DISM /Cleanup-Image /StartComponentCleanup /ResetBase`, re-exports `install.wim` to reclaim space, and re-exports `boot.wim` (which servicing inflates), preserving the bootable flag on the Windows Setup index. With `-CompressEsd` the install image is written as `install.esd` instead, using recovery compression.
8.  **Add the answer file** — If `-UnattendPath` was supplied, copies it to the root of the media as `autounattend.xml`.
9.  **Recompile the ISO** — Uses `oscdimg` to build a new bootable ISO, preserving both the **BIOS (`etfsboot.com`)** and **UEFI (`efisys.bin`)** boot sectors so the media boots on legacy and modern PCs alike.
10. **Clean up** — Removes the extracted working files, leaving the finished ISO.

## How Files Are Downloaded

- The **ISO** link is resolved by the third-party **Fido** helper, which queries Microsoft's own software-download servers. If you prefer not to run external code, supply your own ISO with `-IsoPath`, or use `-UseMct` to get the ISO from Microsoft's own signature-verified Media Creation Tool instead.
- The **updates** are located by parsing the Microsoft Update Catalog search results and its download dialog (the same technique community tools use), then downloaded directly from Microsoft's update servers.
- Downloads prefer **BITS** (resumable) and fall back to `Invoke-WebRequest`. Every resolved URL is verified to point at an official Microsoft host (`microsoft.com`, `windowsupdate.com`) over HTTPS before it is downloaded.

## Design Notes

### Why Updates Are Not Pre-Checked Against the ISO

The script does not inspect the image's patch level before downloading and applying an update. It downloads the latest cumulative update and hands it to DISM regardless. This is deliberate.

Re-applying an update that is already present is safe. Cumulative updates supersede one another, and DISM returns `0x800f081e` ("not applicable") when the package is already in the image. The script treats that as success and moves on, so the only cost of a redundant apply is time.

A pre-check would have to answer "is this KB already in this image?", and that is harder than it looks:

- The image reports a **build and UBR** (for example `26100.4946`), read from the `SOFTWARE` hive of a mounted image. The Microsoft Update Catalog reports a **KB number**. Nothing in either source maps one to the other, so the check needs a separate KB-to-UBR table scraped from Microsoft's release-health pages — a new dependency on HTML that Microsoft is free to restructure.
- The `SPBuild` value in the WIM header is the only patch level available without mounting, and it is frequently stale on Microsoft-published media. Trusting it would produce wrong answers; not trusting it means paying for a read-only mount before the check is worth anything.
- Out-of-band releases and newly published updates are missing from the table until it is re-synced, so the lookup has to **fail open** and apply the update anyway. The code would therefore do nothing in exactly the cases where certainty matters most.

The payoff is small as well. Official Microsoft media usually lags the current cumulative update by months, so "already up to date" is the rare case rather than the common one — and even when it happens, only the update download and one mount are skipped. The Setup Dynamic Update, `boot.wim` servicing, component cleanup, re-export and `oscdimg` rebuild all still run.

Weighed together, the current behaviour risks **wasted minutes in an uncommon case**, while the pre-check would risk **shipping an unpatched ISO because a lookup went stale**. The second failure is far worse and much quieter, so the check is intentionally left out.

## Disk Space Requirements

Because the download, the extracted media, the mounted image, and the re-exported image all coexist, the working drive should have at least **50 GB free**. The script checks this up front and stops if the working drive is too small — choose a larger drive with `-WorkPath` if needed.

The shrink steps near the end of the build stage a second copy of the image beside the original, so each one re-checks free space first. If the drive has filled up, that step is skipped with a warning and the build still finishes — the ISO is just larger than it could have been.

## Where Files Are Written

Everything the script writes lives under a single working folder, which defaults to `<SystemDrive>\WISO-Work`. The script prints this layout before it asks for confirmation, so you can see exactly what it will touch:

```text
C:\WISO-Work\              <- -WorkPath (moves everything below it)
  ISO\                     <- extracted media, deleted when the build finishes
  Mount\                   <- DISM mount point
  Downloads\               <- -DownloadPath (source ISO, updates, and the finished ISO)
  Logs\                    <- -LogPath
```

Dropping your own `.iso` into `Downloads\` is all it takes to skip the Microsoft download — no `-IsoPath` needed. `-DownloadPath`, `-LogPath` and `-OutputIsoPath` override the individual folders if you want them elsewhere. Nothing outside these folders is changed — all servicing happens against files in the working folder, never against the running system.

## Logging

Each run writes a timestamped transcript to `<WorkPath>\Logs` (or `-LogPath`) named `Windows-ISO-Updater_<date>_<time>.log`. The 30 most recent logs are kept and older ones are pruned automatically.
