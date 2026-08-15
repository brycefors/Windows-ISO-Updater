[← Back to the README](../README.md)

# Reference

## What the Script Does

1.  **Locate `oscdimg.exe`** — Downloads a standalone copy from Microsoft's symbol server if it is not already installed (or installs the ADK with `-InstallAdk`), and otherwise fails fast so the build cannot get most of the way through and then be unable to recompile the ISO.
2.  **Obtain the ISO** — Uses `-IsoPath` if given, otherwise reuses the largest `.iso` over 3 GB already sitting in the download folder, and only if neither is available downloads the matching official Microsoft ISO via the community [Fido](https://github.com/pbatard/Fido) helper (verified and sandboxed in its own process — see [Important Notes](../README.md#important-notes)). Blocked link requests are retried with a growing delay, and Microsoft's signature-verified Media Creation Tool can be used as a guided fallback (`-UseMct`).
3.  **Extract the ISO** — Mounts the ISO and mirrors its contents into the working folder with `robocopy`, then dismounts. If the media ships `install.esd`, it is converted to an editable `install.wim`.
4.  **Find the updates** — Detects the feature update (e.g. `24H2`) and architecture from the image, then downloads the latest combined Servicing Stack + Cumulative Update (and, by default, the .NET cumulative update — disable with `-SkipDotNet`, and the Setup Dynamic Update — disable with `-SkipSetupDU`) from the Microsoft Update Catalog. If the image is confirmed to already be at the build that cumulative update delivers, it is neither downloaded nor applied. `-UpdatePath` uses your own packages instead.
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

## Disk Space Requirements

Because the download, the extracted media, the mounted image, and the re-exported image all coexist, the working drive should have at least **50 GB free**. The script checks this up front and stops if the working drive is too small — choose a larger drive with `-WorkPath` if needed.

The shrink steps near the end of the build stage a second copy of the image beside the original, so each one re-checks free space first. If the drive has filled up, that step is skipped with a warning and the build still finishes — the ISO is just larger than it could have been.

## Where Files Are Written

Everything the script writes lives under a single working folder, which defaults to `<SystemDrive>\WISO-Work`. The script prints this layout before it asks for confirmation, so you can see exactly what it will touch:

```text
C:\WISO-Work\              <- -WorkPath (moves everything below it)
  ISO\                     <- extracted media, deleted when the build finishes
  Mount\                   <- DISM mount point
  Downloads\               <- -DownloadPath (source ISO and updates)
  Output\                  <- the finished ISO (-OutputIsoPath overrides it)
  Logs\                    <- -LogPath
```

Dropping your own `.iso` into `Downloads\` is all it takes to skip the Microsoft download — no `-IsoPath` needed. The finished ISO is written to `Output\` instead, so a previous build is never picked up as the source for the next one. `-DownloadPath`, `-LogPath` and `-OutputIsoPath` override the individual folders if you want them elsewhere. Nothing outside these folders is changed — all servicing happens against files in the working folder, never against the running system.

## Logging

Each run writes a timestamped transcript to `<WorkPath>\Logs` (or `-LogPath`) named `Windows-ISO-Updater_<date>_<time>.log`. The 30 most recent logs are kept and older ones are pruned automatically.
