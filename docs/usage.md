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
- The default "keep only one edition" rule picks **Standard (Desktop Experience)**, not Datacenter. An
  installed Standard server can be upgraded to Datacenter in place with `DISM /Set-Edition`, but
  Datacenter can never be downgraded, so Standard is the edition that leaves both options open. Use
  `-KeepEditions` to pick Datacenter or a Server Core image instead, or `-KeepAllEditions` to keep all
  four.
- Microsoft only publishes a **Setup Dynamic Update** for Server 2025 and newer, so on older Server media
  the script reports that none was found and refreshes the media Setup files from `boot.wim` alone.
- **Passing `-Server` with client media is a fatal error.** The script reads the edition out of the image
  right after extraction and stops with exit code 1 rather than downloading Server updates that DISM would
  refuse to apply. The opposite case, Server media without `-Server`, is only a warning, since a client
  cumulative update simply will not be found.
- **Give Server its own `-StampPath` if you also build client ISOs.** There is one `last-build.json` per
  stamp folder, so a Server run and a Windows 11 run sharing the default folder overwrite each other's
  state and both rebuild from scratch every time. `-AutoClean` has the same problem, it deletes the update
  packages the other flavour downloaded.

  ```shell
  .\Run-Windows-ISO-Updater.bat -Server -IsoPath "C:\ISOs\Server2025.iso" -StampPath "C:\WISO-Work\Stamps\Server2025"
  .\Run-Windows-ISO-Updater.bat -WindowsVersion 11 -StampPath "C:\WISO-Work\Stamps\Win11"
  ```

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

A Windows ISO's `install.wim` usually contains many editions (Home, Home N, Pro, Education, etc.). **By default the script keeps only one edition** and removes the rest, which speeds up servicing and produces a smaller ISO. On client media that is the highest edition present (e.g. Enterprise over Pro, or Pro over Home). On Server media the rule is reversed to the *most upgradeable* edition, Standard over Datacenter, because Standard can be upgraded in place but Datacenter cannot be downgraded. Use `-KeepAllEditions` to keep every edition, or `-KeepEditions` to choose exactly which ones to keep.

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
