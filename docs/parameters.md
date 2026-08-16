[← Back to the README](../README.md)

# Command-Line Parameters

The script supports the following optional parameters:

| Parameter | Description |
|---|---|
| `-Unattended` | Runs the script without any confirmation prompts. |
| `-IsoPath` | Path to an existing Windows ISO to update instead of downloading one from Microsoft. May also be a **folder**, in which case the largest `.iso` over 3 GB directly inside it is used. That search is **not recursive**, so an ISO in a subfolder is not found. Omit the parameter entirely and the same rule is applied to the download folder. An ISO on a cloud-synced or network path is copied to the download folder first. |
| `-WindowsVersion` | Windows version to download/update: `10` or `11`. Defaults to `11`. |
| `-Server` | Service **Windows Server** media (2016 through 2025) instead of a client ISO. Server ISOs cannot be downloaded automatically, so supply one with `-IsoPath` or drop it into the download folder. `-WindowsVersion`, `-Release` and `-Language` are then ignored, and the catalog is searched for the Server cumulative update instead of the client one. A mismatch is fatal both ways round: passing this against client media, or omitting it against Server media, stops the run. |
| `-Release` | Fido release to request (e.g. `24H2`, `23H2`) or `Latest`. Defaults to `Latest`. |
| `-Language` | ISO language as named by Microsoft/Fido (e.g. `English`, `"English International"`). Defaults to `English`. |
| `-Edition` | Which edition inside `install.wim` to service: `All` (default) or an edition name like `"Windows 11 Pro"`. |
| `-KeepEditions` | Editions to **keep** in the final ISO, removing the rest to slim it down. Accepts edition names (partial matches allowed) or index numbers, comma-separated. Overrides the default of keeping the highest edition plus Home. |
| `-KeepAllEditions` | Keep **every** edition in the final ISO. By default only some are kept: on client media the highest edition present plus Home (e.g. Pro and Home, or just the highest when the media has no Home edition), or on Server media a single edition, the most upgradeable one (Standard over Datacenter, since Standard can be upgraded in place with `DISM /Set-Edition` but Datacenter cannot be downgraded). |
| `-ListEditions` | List the editions/indexes inside the ISO's `install.wim` and exit, without downloading updates or building anything. Useful for choosing `-Edition`/`-KeepEditions` values. |
| `-UpdatePath` | Folder containing your own `.msu`/`.cab` update packages to integrate instead of fetching from the Microsoft Update Catalog. |
| `-SkipDotNet` | Skip the **.NET cumulative update**. The .NET update is downloaded and integrated **by default**, so use this switch to leave it out. |
| `-SkipSetupDU` | Skip the **Setup Dynamic Update**, which refreshes the loose Windows Setup files in the media's `sources` folder. It is applied **by default**. Without it the Windows 11 24H2+ Setup engine can fail with *"Windows 11 installation has failed"*. |
| `-ServiceWinRE` | Also service the recovery image (`winre.wim`). Off by default. The Safe OS Dynamic Update is used when available. |
| `-SkipUpdates` | Skip update integration entirely and just extract and recompile the ISO. |
| `-CompressEsd` | Export the finished image as `install.esd` (LZMS "recovery" compression) instead of `install.wim`. Typically **25-40% smaller**, which can bring the image under the 4 GB FAT32 limit for UEFI USB sticks, but the export is slow and the finished media cannot be serviced again without converting it back. |
| `-SkipImageCleanup` | Leave each mounted image exactly as DISM left it. By default, servicing residue is stripped before the image is committed: the CBS/DISM/DPX/MoSetup/WindowsUpdate logs, `Windows\Temp`, `SoftwareDistribution\Download`, `$WinREAgent` and the Panther logs, plus anything that never belongs in clean Microsoft media such as `$Recycle.Bin`, `System Volume Information`, `Windows.old` or a stray `pagefile.sys`. Windows recreates all of it on first boot, so use this only when you need to inspect what servicing produced. The ISO comes out larger. |
| `-UnattendPath` | Path to an unattended answer file to place on the finished ISO as `\autounattend.xml`, so Windows Setup runs without prompting. |
| `-SkipTattoo` | Do not tattoo the finished ISO. By default a `\WISO-Build` folder is written onto the media recording what the ISO was built from, which updates applied or failed, what was kept and stripped, who built it and when, plus a copy of the script that built it ([details](reference.md#the-build-record-on-the-iso)). |
| `-DownloadPath` | Directory to download the ISO/updates into. Defaults to a `Downloads` folder inside the working folder. |
| `-WorkPath` | Working folder used to extract and service the media. Defaults to `<SystemDrive>\WISO-Work`. Must be on a local disk: a UNC path, a mapped network drive, or a drive letter that does not exist in the current session is rejected before the build starts. Give each Windows version its own, otherwise they share downloads and build stamps ([why](usage.md#building-several-windows-versions-side-by-side)). |
| `-OutputIsoPath` | Full path for the recompiled ISO. Defaults to the `Output\` folder under the working folder, named after the contents and the patched build, e.g. `Win11_Pro_x64_26100.4061_20260815-1332.iso`. |
| `-VolumeLabel` | Volume label written into the finished ISO, which is what File Explorer shows and what Rufus and Ventoy copy onto the USB stick. Defaults to a label describing the contents, e.g. `WIN11_MULTI_X64_26100_4652`. Maximum 32 characters, letters, digits, `_`, `-` and `.` only, no spaces. |
| `-OscdimgPath` | Full path to `oscdimg.exe` if the Windows ADK is installed in a non-standard location. |
| `-SkipOscdimgDownload` | Do not download a standalone `oscdimg.exe` from Microsoft's symbol server. Require the Windows ADK instead. |
| `-InstallAdk` | If `oscdimg.exe` is not found and cannot be downloaded, download and silently install the ADK Deployment Tools from Microsoft. |
| `-UseFido` | Download the ISO with the Fido helper when you have not supplied one. **Off by default**, because Microsoft blocks Fido's link requests often enough that passing your own ISO is the more reliable way to run the script ([why](design-notes.md#why-the-iso-has-to-come-from-you)). |
| `-FidoUrl` | Override the URL used to fetch the Fido download helper. Must still point at the official `github.com/pbatard/Fido` repository. |
| `-FidoSha256` | Pin the expected SHA-256 of `Fido.ps1` so only that reviewed version is ever run. |
| `-FidoRetryCount` | Extra attempts to make when Fido cannot resolve a download link (Microsoft's anti-bot check is often transient). Defaults to `2`, and `0` disables retrying. |
| `-UseMct` | Get the ISO with Microsoft's Media Creation Tool instead of supplying one yourself or using `-UseFido`. MCT has no headless mode, so you click through its last few pages and save the ISO into the download folder. |
| `-MctUrl` | Override the URL used to download the Media Creation Tool. Must still be an official Microsoft URL. |
| `-MctEdition` | Edition passed to MCT's `/MediaEdition` switch (e.g. `Professional`, `Enterprise`). Only used with `-MctPreselect`, and it makes MCT demand a product key. |
| `-MctPreselect` | Launch MCT with the architecture/language/edition switches pre-filled. Off by default: driving MCT that way sends it down the "enter your product key" flow. |
| `-MctLangCode` | Locale code passed to MCT's `/MediaLangCode` switch (e.g. `en-US`). Derived from `-Language` when not set. |
| `-AdkSetupUrl` | Override the URL used to download the Windows ADK setup bootstrapper. |
| `-OscdimgUrl` | Override the Microsoft symbol server URL used to download the standalone `oscdimg.exe`. |
| `-OscdimgSha256` | Expected SHA-256 of the downloaded `oscdimg.exe`. Pass an empty string to skip the hash check when overriding `-OscdimgUrl`. |
| `-LogPath` | Directory to write log files to. Defaults to a `Logs` folder inside the working folder. |
| `-SkipInteractive` | Skips the interactive confirmation prompt (still shows output). |

## Scheduled runs, build stamps and housekeeping

See [Scheduled Runs](scheduled-runs.md) for how these fit together.

| Parameter | Description |
|---|---|
| `-Scheduled` | Run as an unattended job: no prompts, no "press enter to exit", and the whole build is skipped when the stamp shows nothing has changed. This is what `-RegisterScheduledTask` puts on the task's command line. |
| `-Force` | Build even when the stamp says nothing has changed. |
| `-CheckOnly` | Only report whether a rebuild is needed, then exit without downloading or building. Exit code `0` = nothing to do, `10` = a rebuild is needed. |
| `-NoStamp` | Ignore the stamps completely: do not read one to skip the run, and do not write one at the end. |
| `-StampPath` | Directory to keep the build stamps in. Defaults to a `Stamps` folder inside the working folder. Point several machines at a share to give them one shared history. |
| `-StampHistoryCount` | How many past stamps to keep in `Stamps\History`. Defaults to `30`. |
| `-AutoClean` | After a successful build, delete the update packages this script downloaded for **earlier** builds and every generated ISO except the newest few. Only files recorded in a stamp are ever deleted, so anything else in those folders is left alone. |
| `-KeepIsoCount` | How many generated ISOs `-AutoClean` keeps (newest first). Defaults to `3`. |
| `-RegisterScheduledTask` | Create (or update) a scheduled task that runs this script with the other parameters you passed, then exit without building. The task runs as `SYSTEM` with the highest privileges. |
| `-UnregisterScheduledTask` | Delete the scheduled task named by `-TaskName`, then exit. |
| `-Schedule` | How often the registered task runs: `Hourly`, `Daily`, `Weekly`, `Monthly` or `PatchTuesday`. Defaults to `Monthly`. `PatchTuesday` runs on the second Tuesday of every month without you having to work out the date. |
| `-ScheduleTime` | Time of day the registered task starts, as 24-hour `HH:mm`. Defaults to `03:00`, or for `-Schedule PatchTuesday` to whatever **10:30 Pacific** works out to in this machine's time zone, daylight saving included. |
| `-ScheduleDay` | Which day the registered task runs: a weekday name for `-Schedule Weekly` (default `Sunday`), or a day number `1`-`31` for `-Schedule Monthly` (default `15`, a few days after Patch Tuesday). Ignored by `-Schedule PatchTuesday`. |
| `-TaskName` | Name of the scheduled task to create or delete. Defaults to `Windows ISO Updater`. |
