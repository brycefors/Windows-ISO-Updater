[← Back to the README](../README.md)

# Command-Line Parameters

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
| `-SkipDotNet` | Skip the **.NET cumulative update**. The .NET update is downloaded and integrated **by default**, so use this switch to leave it out. |
| `-SkipSetupDU` | Skip the **Setup Dynamic Update**, which refreshes the loose Windows Setup files in the media's `sources` folder. It is applied **by default**. Without it the Windows 11 24H2+ Setup engine can fail with *"Windows 11 installation has failed"*. |
| `-ServiceWinRE` | Also service the recovery image (`winre.wim`). Off by default. The Safe OS Dynamic Update is used when available. |
| `-SkipUpdates` | Skip update integration entirely and just extract and recompile the ISO. |
| `-CompressEsd` | Export the finished image as `install.esd` (LZMS "recovery" compression) instead of `install.wim`. Typically **25-40% smaller**, which can bring the image under the 4 GB FAT32 limit for UEFI USB sticks, but the export is slow and the finished media cannot be serviced again without converting it back. |
| `-UnattendPath` | Path to an unattended answer file to place on the finished ISO as `\autounattend.xml`, so Windows Setup runs without prompting. |
| `-DownloadPath` | Directory to download the ISO/updates into. Defaults to the script folder. |
| `-WorkPath` | Working folder used to extract and service the media. Defaults to `<SystemDrive>\WISO-Work`. |
| `-OutputIsoPath` | Full path for the recompiled ISO. Defaults to the `Output\` folder under the working folder, named after the contents and the patched build, e.g. `Win11_Pro_x64_26100.4061_20260815-1332.iso`. |
| `-OscdimgPath` | Full path to `oscdimg.exe` if the Windows ADK is installed in a non-standard location. |
| `-SkipOscdimgDownload` | Do not download a standalone `oscdimg.exe` from Microsoft's symbol server. Require the Windows ADK instead. |
| `-InstallAdk` | If `oscdimg.exe` is not found and cannot be downloaded, download and silently install the ADK Deployment Tools from Microsoft. |
| `-FidoUrl` | Override the URL used to fetch the Fido download helper. Must still point at the official `github.com/pbatard/Fido` repository. |
| `-FidoSha256` | Pin the expected SHA-256 of `Fido.ps1` so only that reviewed version is ever run. |
| `-FidoRetryCount` | Extra attempts to make when Fido cannot resolve a download link (Microsoft's anti-bot check is often transient). Defaults to `2`, and `0` disables retrying. |
| `-UseMct` | Skip Fido and get the ISO with Microsoft's Media Creation Tool instead. MCT has no headless mode, so you click through its last few pages and save the ISO into the download folder. |
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
