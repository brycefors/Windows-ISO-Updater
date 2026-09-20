[← Back to the README](../README.md)

# Scheduled Runs

A full build takes an hour or two and needs tens of gigabytes of scratch space, so a scheduled task that
rebuilds blindly on a timer wastes most of its runs. Instead, every finished build writes a **stamp**,
a small JSON record of what went into it, and the next run compares itself with that stamp *before* it
extracts anything. When nothing has changed it exits in a minute or two.

That makes it safe to schedule the script as often as you like. Hourly is fine.

## Registering the task

```shell
:: Monthly, on the 15th at 03:00 - the default
.\Run-Windows-ISO-Updater.bat -RegisterScheduledTask -AutoClean -IsoPath "C:\ISOs\Win11_25H2.iso"

:: Second Tuesday of every month, half an hour after Microsoft publishes - i.e. Patch Tuesday itself
.\Run-Windows-ISO-Updater.bat -RegisterScheduledTask -Schedule PatchTuesday -AutoClean

:: Daily at 02:30
.\Run-Windows-ISO-Updater.bat -RegisterScheduledTask -Schedule Daily -ScheduleTime 02:30 -AutoClean

:: Every Sunday at 01:00
.\Run-Windows-ISO-Updater.bat -RegisterScheduledTask -Schedule Weekly -ScheduleDay Sunday -ScheduleTime 01:00

:: Every hour, on the hour
.\Run-Windows-ISO-Updater.bat -RegisterScheduledTask -Schedule Hourly -ScheduleTime 00:00

:: Remove it again
.\Run-Windows-ISO-Updater.bat -UnregisterScheduledTask
```

Whatever other parameters you pass are baked into the task's command line, with `-Scheduled` added so it
never waits at a prompt. The task runs as **SYSTEM** with the highest privileges, so every path it uses
must be a local path SYSTEM can reach, not a mapped drive, and not a cloud-synced user folder such as
`My Drive` or `OneDrive`.

One task keeps one Windows version up to date. To schedule several, give each its own `-TaskName` and its
own `-WorkPath`, and stagger the start times so two builds never overlap. See
[Building Several Windows Versions Side by Side](usage.md#building-several-windows-versions-side-by-side).

`-Schedule Monthly` uses `-ScheduleDay` as a day of the month (`1`-`31`), while `-Schedule Weekly` uses it
as a weekday name.

### `-Schedule PatchTuesday`

A slightly silly flag that happens to be the most sensible schedule here: it works out the second Tuesday
of each month for you, rather than making you translate Patch Tuesday into a day number that drifts every
month. `-ScheduleDay` is ignored.

Microsoft publishes at around 10:00 Pacific, so the default start time is **10:30 Pacific converted into
this machine's time zone**, which is 13:30 on the US east coast, 18:30 in the UK, and so on. Daylight
saving is accounted for: the local equivalent is worked out for each of the next twelve Patch Tuesdays and
the *latest* one wins, so a Pacific/local DST mismatch can make a run half an hour late but never early. A
late run costs nothing, while an early one finds nothing new and then waits a whole month.

`-ScheduleTime` still overrides it, with a warning if you pick a time before the packages are published.

Far enough east, anywhere 10:30 Pacific falls on the following local day, the task is registered for the
**second and third local Wednesday** instead, since the Wednesday after the second Tuesday is not always in
the same week of the month. One of those two runs lands just after the release and the other exits in a
minute having found nothing new.

## What the stamp records

Stamps live in `<WorkPath>\Stamps` (move them with `-StampPath`):

* `last-build.json` holds the newest build. This is the one the next run compares against.
* `History\stamp_<date>_<time>.json` is one copy per build, newest `-StampHistoryCount` kept (default 30).

Each stamp holds:

| Section | Contents |
|---|---|
| `Source` | The source ISO's path, size, write time and **SHA-256**. |
| `Image` | The build, UBR, feature update (e.g. `25H2`) and architecture read out of the image. |
| `Updates.Catalog` | What the Microsoft Update Catalog was offering at build time, as `Role=KB@date` (e.g. `LCU=KB5065426@2026-08-12`). |
| `Updates.Files` | Every package that was integrated: file name, KB, size and SHA-256. |
| `Output` | The finished ISO's path, size, editions and SHA-256. |
| `Parameters` / `ParametersHash` | Every parameter that changes what ends up in the ISO, plus a hash of the answer file's **contents**. |

## When a run decides to rebuild

A rebuild happens if any of these is true:

* there is no stamp yet (first run),
* the source ISO's SHA-256 differs from the one in the stamp,
* a build-affecting parameter changed, including editing the `-UnattendPath` answer file in place, dropping a newer driver into the `-DriverPath` folder, or changing anything in the `-ExtraFilesPath` folder,
* the catalog is offering a different, newer or additional update than the stamp recorded,
* the ISO the last build produced is no longer on disk.

Otherwise the run stops and says so. `-Force` builds anyway.

If the update catalog cannot be reached at all, the run assumes nothing new has been published and skips
rather than burning two hours on a network blip. The next scheduled run looks again.

Hashing the source ISO is skipped when it is provably the same file as last time (same path, size and
write time), so an hourly check does not re-read 8 GB every hour.

### Checking without building

`-CheckOnly` answers the question and exits without downloading or building anything:

```shell
.\Run-Windows-ISO-Updater.bat -CheckOnly
```

Exit code `0` means nothing to do, `10` means a rebuild is needed, `1` means the check itself failed.

## Housekeeping with -AutoClean

`-AutoClean` runs after a successful build (and after a skipped one) and:

* deletes the update packages **this script downloaded** for earlier builds, keeping the ones the newest
  build uses,
* deletes generated ISOs, keeping the newest `-KeepIsoCount` (default `3`).

It only ever deletes files that a stamp recorded, so an ISO you dropped in yourself, packages you pointed
at with `-UpdatePath`, and anything else living in those folders are never touched. The source ISO the
current run is using is always protected.

The folder it prunes is the one the ISO is written to, so pointing `-OutputIsoPath` at a folder of your own
moves the pruning there as well, including a share (the stamp records where the ISO ended up, not the local
folder it was staged in). Only files matching this script's own generated name, right down to the
`_yyyyMMdd-HHmm` stamp, are candidates, so anything you named yourself is safe. Note that `-KeepIsoCount`
applies to that folder as a whole: aiming a Windows 10 run and a Windows 11 run at one shared output folder
makes them compete for the same slots.

```shell
:: Keep the last five generated ISOs instead of three
.\Run-Windows-ISO-Updater.bat -Scheduled -AutoClean -KeepIsoCount 5
```

## Injecting Drivers on a Schedule

If you already have a fully patched ISO on disk and want to refresh drivers on a schedule without
re-downloading and re-integrating Windows updates every time, combine `-SkipUpdates` and `-DriverPath`
in your scheduled task registration. The Microsoft Update Catalog check is skipped entirely, so the run
completes in a few minutes instead of an hour.

**How the stamp handles drivers**

The entire contents of the `-DriverPath` folder (every `.inf` file and supporting files, searched
recursively) are hashed and included in the build stamp. If you download and extract a newer driver
package into the folder, the content hash changes, and the next scheduled run detects this and rebuilds,
even though the source ISO and Windows updates are unchanged. This means once you register the task, you
only need to refresh the driver files in the folder, and the schedule takes care of the rest.

**Example: VMware Tools drivers, injected monthly**

Register a task that injects VMware Tools drivers into an already-patched Windows 11 ISO:

```shell
.\Run-Windows-ISO-Updater.bat -RegisterScheduledTask ^
  -IsoPath "C:\ISOs\Win11_25H2_x64.iso" ^
  -SkipUpdates ^
  -DriverPath "D:\Drivers\VMware-Tools" ^
  -Schedule Monthly ^
  -ScheduleDay 1 ^
  -ScheduleTime 02:00 ^
  -AutoClean
```

The task runs on the 1st of each month at 02:00. Each time it runs:

* If the driver folder contents have not changed since the last build, the stamp matches and the run exits
  in 1-2 minutes with no rebuild.
* If you have downloaded and extracted a newer VMware Tools driver package into `D:\Drivers\VMware-Tools`
  between runs, the content hash differs and a rebuild is triggered.
* If the source ISO is replaced with a newer one at the same path, that too is detected and triggers a rebuild.

**The role of `-SkipUpdates`**

`-SkipUpdates` tells the script to skip checking the Microsoft Update Catalog and downloading/integrating
any updates. Without it, the task would check for new cumulative updates every run, which is fine if you
want the ISO to stay current with both updates and drivers, but wastes time if the ISO is already at the
patch level you want and you only care about drivers. With `-SkipUpdates` in effect, the only rebuild
trigger is a change to the driver folder, the source ISO, or a parameter you explicitly alter.

**Adding `-AllowUnsignedDrivers` for self-signed drivers**

If your driver package includes unsigned or self-signed drivers that DISM would normally reject, add
`-AllowUnsignedDrivers` to the registration command. Keep in mind that 64-bit Windows itself still refuses
to load an unsigned kernel driver at boot unless test signing is enabled on the target machine, so this
flag only affects what DISM accepts during the build. See [Adding Drivers](usage.md#adding-drivers) for
more detail on driver extraction and requirements.

**A gotcha with very old media**

On media older than Windows 10 (build 10240) and Windows Server 2016, DISM cannot mount or service the
images. If you try to use `-DriverPath` against such media, even with `-SkipUpdates`, the task still fails
because driver injection requires the images to be mounted. For pre-Windows 10 media, `-SkipUpdates` alone
(without `-DriverPath`) repacks the ISO unchanged.

[← Back to README](../README.md)
