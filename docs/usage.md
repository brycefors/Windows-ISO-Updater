[← Back to the README](../README.md)

# How to Run This Script

The easiest and recommended way to run this script is by using the `Run-Windows-ISO-Updater.bat` file. It automatically handles administrator elevation and PowerShell execution policies, and will download the latest `Windows-ISO-Updater.ps1` from GitHub if it is missing.

**As long as you use the batch file, no setup or PowerShell experience is needed.** It requests administrator rights through the normal UAC prompt, downloads the script over HTTPS from the official [Windows-ISO-Updater](https://github.com/brycefors/Windows-ISO-Updater) repository if it is not already next to it, and runs it with `-ExecutionPolicy Bypass` scoped to that single run, so your system-wide execution policy is never changed. Running the `.ps1` by hand works too, but then elevation and execution policy are on you.

## Recommended Method: Using the Batch File

1.  **Download Files:** Make sure both `Run-Windows-ISO-Updater.bat` and `Windows-ISO-Updater.ps1` are saved in the **same folder**. (If the `.ps1` is missing, the batch file will download it automatically.)
2.  **Run the Batch File:** Double-click the `Run-Windows-ISO-Updater.bat` file.
3.  **Administrator Prompt:** A User Account Control (UAC) window will appear asking for administrative privileges. Click **Yes**.
4.  **Follow Prompts:** The script opens in a new window, summarizes what it will do, and asks for confirmation before downloading and building.

## Running with Parameters (from Command Line)

To use command-line parameters, run the batch file from a Command Prompt or PowerShell terminal.

1.  Open Command Prompt or PowerShell.
2.  Navigate to the directory where you saved the files (e.g., `cd C:\Users\YourUser\Downloads`).
3.  Run the batch file with your desired parameters. For example:
    ```shell
    .\Run-Windows-ISO-Updater.bat -Unattended -InstallAdk -Edition "Windows 11 Pro"
    ```

The full list is in [Command-Line Parameters](parameters.md).

## Updating a Windows Server ISO

Pass `-Server` to service Windows Server media (2016 through 2025). Everything else works the same way,
but the ISO has to come from you: neither Fido nor the Media Creation Tool serves Server media, so
download it from the [Microsoft Evaluation Center](https://www.microsoft.com/evalcenter), your Volume
Licensing Service Center, or a Visual Studio subscription first.

```shell
:: Slipstream the latest Server cumulative update into your own Server 2025 ISO
.\Run-Windows-ISO-Updater.bat -Server -IsoPath "C:\ISOs\Server2025.iso"

:: Or drop the ISO into the download folder and let it be picked up automatically
.\Run-Windows-ISO-Updater.bat -Server
```

A few differences worth knowing:

- The release is read from the image, so there is no `-Release` to set. Server 2022 and newer are listed
  in the Microsoft Update Catalog as *"Microsoft server operating system version 21H2/23H2/24H2"* rather
  than by year, and the script builds the right query for you.
- Server media keeps a **single** edition by default, not the two that client media keeps, and the pick is
  **Standard (Desktop Experience)**, not Datacenter. An installed Standard server can be upgraded to
  Datacenter in place with `DISM /Set-Edition`, but Datacenter can never be downgraded, so Standard is the
  edition that leaves both options open. Use `-KeepEditions` to pick Datacenter or a Server Core image
  instead, or `-KeepAllEditions` to keep all four.
- Microsoft only publishes a **Setup Dynamic Update** for Server 2025 and newer, so on older Server media
  the script reports that none was found and refreshes the media Setup files from `boot.wim` alone.
- **A mismatch between the media and the switch is a fatal error, both ways round.** The script reads the
  edition out of the image right after extraction, and stops with exit code 1 if `-Server` was passed
  against client media or omitted against Server media, rather than downloading updates that DISM would
  refuse to apply.
- **Give Server its own working folder if you also build client ISOs.** See
  [Building Several Windows Versions Side by Side](#building-several-windows-versions-side-by-side).

## Building Several Windows Versions Side by Side

Everything the script writes lives under one working folder, `C:\WISO-Work` unless you pass `-WorkPath`.
That is deliberate, because a single parameter moves the whole build to another drive, but it does mean a
Windows 11 run and a Windows 10 or Server run share the same downloads, the same build stamps and the same
scratch space. Nothing in the folder layout is scoped by version.

**Give each version its own `-WorkPath`.** That one parameter separates all of it, and there is nothing
else to configure.

```shell
:: Windows 11, the usual case
.\Run-Windows-ISO-Updater.bat -WindowsVersion 11 -WorkPath "D:\WISO\Win11"

:: Windows 10, completely independent of the run above
.\Run-Windows-ISO-Updater.bat -WindowsVersion 10 -Release 22H2 -WorkPath "D:\WISO\Win10"

:: Windows Server, which needs an ISO you supply
.\Run-Windows-ISO-Updater.bat -Server -IsoPath "C:\ISOs\Server2025.iso" -WorkPath "D:\WISO\Server2025"
```

The same applies to two builds of the *same* Windows version that differ in a build-affecting way, such as
one ISO with an answer file and one without, or one trimmed to Pro only and one with every edition. They
are different outputs, so they need different working folders.

### What actually collides

If you would rather share most of the folders and split only what matters, this is what each one does when
two versions share it:

| Folder | Effect of sharing it |
|---|---|
| `Downloads` | **The worst one.** With no `-IsoPath`, the script reuses the largest `.iso` over 3 GB it finds here, and it does **not** check which Windows version that ISO is. A Windows 10 ISO left in the folder is picked up by a Windows 11 run. Split it with `-DownloadPath`, or always pass `-IsoPath`. |
| `Stamps` | There is one `last-build.json` per stamp folder. Alternating versions overwrite each other's record, so every run decides it must rebuild and `-CheckOnly` always reports a rebuild is needed. Split it with `-StampPath`. |
| `Downloads` (update packages) | `-AutoClean` deletes the `.msu`/`.cab` files recorded in stamp history that the newest build no longer uses, so it deletes the other version's cumulative update. Splitting `-DownloadPath` and `-StampPath` fixes this too. |
| `Output` | Safe. Finished ISO names carry the version (`Win11_`, `Win10_`, `Server2025_`), so they coexist. Note that `-AutoClean` keeps the newest `-KeepIsoCount` (default 3) across **all** versions combined, not per version. |
| `Logs` | Safe, but log rotation keeps the 30 most recent overall, so history is shorter the more versions you run. |
| `ISO`, `Mount`, `Tools` | Safe between runs, since extraction wipes the `ISO` folder at the start of every build anyway. Not safe **during** a run, see below. |

So the minimum split is `-DownloadPath` and `-StampPath`. A separate `-WorkPath` covers both and is easier
to reason about later.

### Do not run two builds at the same time

The script assumes it is the only copy running. Two builds at once fight over the DISM mount folder and the
extraction folder even if everything else is separate, and a DISM mount is tracked per WIM file, so the
second run fails or corrupts the first. Run them one after another. Scheduled tasks should be given start
times far enough apart that a build cannot still be going, or an hour or two apart.

### A shared ISO library

If you keep source ISOs in one place, point `-IsoPath` at the specific file rather than sharing a download
folder. `-IsoPath` also accepts a folder, but it picks the largest ISO inside it, which is the same trap as
a shared `Downloads` folder.

```shell
.\Run-Windows-ISO-Updater.bat -IsoPath "\\nas\isos\Win11_24H2.iso" -WorkPath "D:\WISO\Win11"
```

A source ISO on a network share or a cloud-synced folder is copied into the download folder first, so the
library itself can live wherever is convenient. The working folder still has to be a local disk.

### On a schedule

Each version needs its own task name as well as its own working folder, otherwise registering the second
one replaces the first.

```shell
.\Run-Windows-ISO-Updater.bat -RegisterScheduledTask -Schedule PatchTuesday -AutoClean ^
  -WindowsVersion 11 -WorkPath "D:\WISO\Win11" -TaskName "Windows ISO Updater - Win11"

.\Run-Windows-ISO-Updater.bat -RegisterScheduledTask -Schedule PatchTuesday -ScheduleTime 20:30 -AutoClean ^
  -Server -IsoPath "C:\ISOs\Server2025.iso" -WorkPath "D:\WISO\Server2025" -TaskName "Windows ISO Updater - Server2025"
```

Both tasks run as SYSTEM, so every path has to be a local path SYSTEM can reach. See
[Scheduled Runs](scheduled-runs.md) for the full details.

## Running It on a Schedule

```shell
:: Rebuild monthly, on the 15th at 03:00, and clean up what earlier builds left behind
.\Run-Windows-ISO-Updater.bat -RegisterScheduledTask -Schedule Monthly -ScheduleDay 15 -ScheduleTime 03:00 -AutoClean

:: Or rebuild on Patch Tuesday itself - the second Tuesday of every month, 10:30 Pacific in local time
.\Run-Windows-ISO-Updater.bat -RegisterScheduledTask -Schedule PatchTuesday -AutoClean
```

The task runs the script with `-Scheduled`, which compares the run against the stamp left by the last
build and exits within a minute or two when nothing has changed, so scheduling it hourly costs nothing.
See [Scheduled Runs](scheduled-runs.md).

## Removing Editions (Slimming the ISO)

A Windows ISO's `install.wim` usually contains many editions (Home, Home N, Pro, Education, etc.). **By default the script keeps the highest edition plus Home** and removes the rest, which speeds up servicing and produces a smaller ISO. On typical consumer media that means Pro and Home, so one ISO still installs either. If the media has no Home edition (business and VL media, for example), only the highest edition is kept. On Server media the rule is different: a single edition, the *most upgradeable* one, Standard over Datacenter, because Standard can be upgraded in place but Datacenter cannot be downgraded. Use `-KeepAllEditions` to keep every edition, or `-KeepEditions` to choose exactly which ones to keep.

Both kept editions are serviced, so a two-edition build takes roughly twice as long as a one-edition build. Pass `-KeepEditions "Windows 11 Pro"` if you only need one and want the shorter run.

```shell
:: See what editions are inside the ISO first (downloads/uses the ISO, then just lists and exits)
.\Run-Windows-ISO-Updater.bat -ListEditions

:: Keep EVERY edition instead of just Pro and Home
.\Run-Windows-ISO-Updater.bat -KeepAllEditions

:: Build an updated ISO containing ONLY Windows 11 Pro (by name)
.\Run-Windows-ISO-Updater.bat -KeepEditions "Windows 11 Pro"

:: Same idea, selecting by index number instead of name
.\Run-Windows-ISO-Updater.bat -KeepEditions 6,1
```

`-KeepEditions` accepts edition names (partial matches allowed) or index numbers, and overrides the default. Only the kept editions are serviced and re-exported, so the removed editions are gone from the final `install.wim`. It works with `-SkipUpdates` too, if you only want to trim editions without integrating updates.
