[← Back to the README](../README.md)

# Design Notes

## Why This Exists

The slowest part of standing up a new Windows machine is not the install. Setup itself finishes in minutes. What takes the rest of the afternoon is the first trip through Windows Update, where a cumulative update that is months behind gets downloaded, staged, installed and rebooted through, while you sit and watch. Do that on one machine and it is an annoyance. Do it on a lab, a classroom or a rack of hosts and it is the whole day.

The updates can obviously wait until later, and often they are told to. That still breaks the thing that matters, which is getting a production-ready system in front of someone quickly. A machine that is installed but not yet patched is not finished. It cannot be handed over, it cannot be imaged from, and it will pick its own moment to reboot. The work is not gone, it is just deferred to a worse time.

Skipping the updates outright is worse still, and how much worse depends entirely on how old the source media is. A months-old ISO is missing every fix published since it was cut, so the machine is exposed for as long as it stays that way. Age also causes plain compatibility trouble. Older media can be missing the servicing stack a current update expects, which is what `0x800F0823` means when it appears, and driver and feature support that shipped in later revisions is simply not there yet.

Slipstreaming the update into the media instead moves all of that work to a machine that has time for it. The install starts already patched, and the hour it used to cost happens once, on the build machine, rather than once per deployment.

There are two more wins that come along for free.

**The image is a real `install.wim` again.** Where you get the ISO decides what compression it uses. The Media Creation Tool and most consumer download routes hand you `install.esd`, which is LZMS "recovery" compressed. It is much smaller on disk, but every byte has to be decompressed during apply, and that is CPU-bound work that makes Setup noticeably slower on modest hardware. This script converts `install.esd` to an editable `install.wim` before it services anything, and writes an `install.wim` back out by default, so the finished media applies faster than what you started with. `-CompressEsd` is there if you would rather have the small file, which is mostly useful for getting under the 4 GB FAT32 limit on a UEFI USB stick.

**The ISO carries only the editions you actually deploy.** Retail media ships eleven or so editions you will never install, and all of them are paid for in size and in the length of the edition-picker during Setup. By default the build keeps the top edition plus Home on client media, or a single edition on Server, and `-KeepEditions` lets you name exactly what stays. Between that and the component-store cleanup, the output is usually smaller than the source despite carrying months of extra updates.

## Why the ISO Has to Come From You

The script does not download a Windows ISO on its own. You pass one with `-IsoPath` or drop one into the download folder, and if neither is there the run stops and tells you so. The automatic download exists, but it is opt-in behind `-UseFido`, and that is deliberate.

It leans on the community [Fido](https://github.com/pbatard/Fido) helper, which asks Microsoft's software-download servers for a link the same way the download page does. Microsoft treats repeated automated requests as abuse, and blocks are common enough that they should be expected rather than treated as a fault:

- *"Error: Sentinel marked this request as rejected"*
- a *715-123130* error on the download page
- a link that resolves but returns an HTML error page instead of 8 GB of ISO

The block is usually per-IP and temporary, so `-UseFido` retries a few times with a growing delay (`-FidoRetryCount`, two extra attempts by default), and the script can then offer Microsoft's Media Creation Tool because MCT talks to different servers and often still works. Both are workarounds for a problem you can avoid outright, and neither is something to build a monthly routine on.

Making the download opt-in also keeps third-party code out of a default run. Fido is not signed, so the script has to verify its source, size, contents and behaviour before executing it (see [Important Notes](../README.md#important-notes)). None of that happens unless you ask for it.

**Download the ISO once, keep it, and point every build at it.** Get it from [microsoft.com/software-download](https://www.microsoft.com/software-download), the Media Creation Tool, the Microsoft Evaluation Center, your Volume Licensing Service Center or a Visual Studio subscription:

```shell
.\Run-Windows-ISO-Updater.bat -IsoPath "D:\ISOs\Win11_24H2_original.iso"
```

That is faster on every run after the first, it does not depend on Microsoft's mood, and it is the only option for Windows Server media, which neither Fido nor MCT serves at all.

It matters most for scheduled tasks. A blocked link request in an unattended run has nothing to fall back on, since the Media Creation Tool cannot run headless, so a task that depends on the automatic download eventually fails for reasons outside your control. A pristine source ISO kept on disk makes the run deterministic, and every build then re-reads the same source, which is exactly what the [rebuild-avoidance model](scheduled-runs.md#when-a-run-decides-to-rebuild) expects.

The one thing to watch is that a source ISO **ages**. It never stops working, because the cumulative update is cumulative, but media several years older than the update can run into `0x800F0823` (*the image needs a newer servicing stack*). Refresh the source ISO once a year or so, and the drift takes care of itself.

## How the Already-Patched Check Works

Integrating a cumulative update is the expensive part of a run (mount, apply, component cleanup, re-export), so the script checks whether the image already has that update before downloading it. Re-applying a present update is harmless (DISM returns `0x800f081e`, "not applicable", and the script treats that as success), but it costs the better part of an hour.

The check has to bridge two things that don't reference each other: the image reports a **build and UBR** (for example `26100.4946`), while the Update Catalog reports a **KB number**. The bridge is the KB's own support page, whose title reads `... KB5062553 (OS Builds 26100.4652 and 26200.4652)`. That gives the UBR the update delivers, before anything is downloaded.

Because a wrong "already patched" decision would quietly ship an unpatched ISO, the check is deliberately asymmetric:

- The WIM header's `SPBuild` is only a **hint**. It is stale on some Microsoft media, so it is used solely to decide whether the question is worth asking.
- If the header suggests the image is current, the image is **mounted read-only** and its real build is read from the `SOFTWARE` hive. Only that confirmed value can trigger a skip.
- Anything unknown (support page unreachable, title format changed, hive unreadable, out-of-band release missing from the page) **fails open** and the update is downloaded and applied as usual.

So the worst case is a few wasted minutes on a confirmation mount, and the update still gets applied. A skip only happens when the image's own registry proves it is already at or past the update's build.

## Why Both boot.wim Indexes Are Serviced

`boot.wim` never becomes the installed OS (index 1 is Windows PE, index 2 is Windows Setup), so patching it looks like time that could be saved. It isn't, and both indexes get the same treatment as `install.wim`:

- **Secure Boot revocations.** The media's `bootmgfw.efi` and `bootmgr.efi` are taken from index 2. Once a machine has the CVE-2023-24932 revocations in its DBX and SBAT, media carrying pre-revocation boot managers will not boot at all, and that failure happens before Setup starts, so there is nothing to recover from.
- **Setup binary version match.** The cumulative update raises the version of `setup.exe` and `setuphost.exe` *inside* index 2. If those don't match the loose copies in the media's `sources` folder, Windows Setup fails with errors such as "A media driver your computer needs is missing." The script therefore copies the serviced binaries out of index 2 and overwrites the ones on the media, after the Setup Dynamic Update has been applied.
- **Inbox drivers.** WinPE's storage, NVMe and network drivers come from the cumulative update. An unpatched WinPE on recent hardware can boot to a Setup screen that sees no disks.

Index 1 is serviced as well rather than index 2 alone. It is the repair and recovery environment launched from the media, and leaving two images inside one WIM at different patch levels is a configuration Microsoft neither ships nor tests.

The .NET cumulative update is offered to `boot.wim` along with everything else, even though WinPE has no .NET Framework to patch. DISM reports it as not applicable (`0x800f081e`) and the run continues, which keeps the servicing order identical for every image at the cost of one wasted package expansion per index.

## What Windows Update Will Still Offer

A machine installed from a freshly built ISO still shows a few pending items on its first check for updates. That is expected rather than a gap in the build: the script integrates component-store packages, and Windows Update also delivers things that are not component-store packages at all. Those cannot be slipstreamed by any means.

- **Standalone tools shipped as an `.exe`.** Some Update Catalog entries are ordinary programs rather than servicing packages. The monthly Malicious Software Removal Tool is the one you will see most often. There is nothing inside them for DISM to bind into an offline image, and a fresh build ships every Patch Tuesday, so a baked-in copy would be superseded within weeks and offered again regardless.
- **Definition updates.** Microsoft Defender's security intelligence and the Windows Security platform updates are classified in the catalog as *Definition Updates*, the same category as virus signatures, and also ship as an `.exe`. They are re-released several times a day, so media is stale before the build finishes.

`DISM /Add-Package` only consumes `.msu`/`.cab` packages that bind into the component store by build number, which is exactly what makes a cumulative update integrable and these not. Passing one to `-UpdatePath` fails its `.msu`/`.cab` check.

So they stay a post-install task. Left alone, Windows Update installs them on its own within a day of the machine going online. If you want them handled deterministically, do it from the answer file rather than the media:

- Pull Defender's platform and intelligence updates at first logon with the in-box client, which needs no download URL:
  ```powershell
  & "$env:ProgramFiles\Windows Defender\MpCmdRun.exe" -SignatureUpdate
  ```
- Stop the removal tool being offered at all, if you consider Defender sufficient, by setting `DontOfferThroughWUAU` to `1` under `HKLM\SOFTWARE\Policies\Microsoft\MRT`.

Neither is worth doing in a gold image before sealing: definitions age out while the image sits in storage, so run them at deployment instead.

## Why Not Re-Update an ISO This Script Built

Feeding last month's output back in as next month's input looks like it should save time. It doesn't, and it costs you things that are hard to get back. **Keep the original Microsoft ISO and rebuild from it every time.**

The saving isn't real. Cumulative updates are cumulative, so applying October's LCU to pristine media does the same work as applying it to media patched in September. It is one package either way, of roughly the same size, and every expensive step is identical: extraction, the DISM mount, `/Add-Package`, the `/ResetBase` component cleanup, `Export-WindowsImage` and `oscdimg`. The only step chaining skips is downloading the ISO, which you already skip by keeping the source on disk and passing `-IsoPath`.

What it breaks:

- **The rebuild-avoidance model.** [`Test-RebuildNeeded`](scheduled-runs.md#when-a-run-decides-to-rebuild) keys on the source ISO's SHA-256. Every build produces a new output with a new hash, so if that output becomes the next input, the source never matches the stamp, every scheduled run rebuilds, and `-CheckOnly` always reports that a rebuild is needed.
- **Failures compound silently.** When a package won't apply, the script warns that the edition *"kept its original patch level"* and finishes the ISO anyway. Against pristine media that is one build you throw away. In a chain, that image becomes the base for every build after it and the drift is invisible.
- **Some choices can't be undone.** Editions dropped in one build are gone from every descendant, so you could not get Home back without starting over. Media built with `-CompressEsd` cannot be serviced again at all, because recovery-compressed images are not mountable for servicing.

Component store growth, the one argument that would favour a fresh base, is already handled: each serviced edition gets `/Cleanup-Image /StartComponentCleanup /ResetBase`, so superseded components are stripped rather than accumulating build over build.

The intended setup is a pristine ISO kept somewhere permanent, with its own working folder:

```shell
.\Run-Windows-ISO-Updater.bat -RegisterScheduledTask -Schedule PatchTuesday -AutoClean ^
  -IsoPath "D:\ISOs\Win11_24H2_original.iso" -WorkPath "D:\WISO\Win11"
```

`-AutoClean` prunes old outputs and superseded update packages on its own, and because it only deletes files a stamp recorded, the source ISO is never touched.

## Why Two Identical Builds Aren't the Same Size

The finished ISO's SHA-256 changes on **every** build, even from the same source and the same update, because `oscdimg` writes timestamps into the ISO and the output file name embeds the build date and time. Byte-identical output was never a goal. Size, though, should be stable to within a few megabytes, and a bigger gap than that is worth explaining.

Offline servicing writes into the image as it works: `Windows\Logs\CBS`, `Windows\Logs\DISM`, `$WinREAgent` state, temp files. How much it writes depends on how chatty DISM was on that particular run, and all of it used to be committed and exported with the image. That was the main source of run-to-run size drift, so every image is now stripped of it just before `Dismount-WindowsImage -Save`:

* Contents of `Windows\Logs\CBS`, `Logs\DISM`, `Logs\DPX`, `Logs\MoSetup`, `Logs\WindowsUpdate`, `Windows\Temp` and `Windows\SoftwareDistribution\Download`, keeping the folders themselves.
* `$WinREAgent`.
* Only the `.log`, `.etl` and `.evtx` files in `Windows\Panther`. The folder is left in place and any XML in it is kept, because a captured image can legitimately keep the answer file that built it there.

Windows recreates all of it on first boot. The same pass also removes `Windows.old`, `$WINDOWS.~BT`, `$WINDOWS.~WS`, `$Recycle.Bin`, `System Volume Information`, `pagefile.sys`, `hiberfil.sys` and `swapfile.sys`, and **warns** when it finds any of them, because none belong in clean Microsoft media. Finding one means the source ISO was built from a captured machine rather than downloaded from Microsoft, which is worth knowing on the first build rather than on the first deployed machine. DISM's default capture exclusion list does not exclude them, so a naive `/Capture-Image` carries them into every deployment.

What remains after that is genuine variance in what `/ResetBase` managed to reclaim, which depends on the component store's state at that moment. Running the cleanup more than once does not help, since a completed `/ResetBase` has already removed every superseded component and a second pass rescans the whole store to reclaim nothing. It also runs per edition, so repeating it is expensive.

If two builds still differ by hundreds of megabytes, compare their stamps rather than guessing. A `Result` of `SuccessWithWarnings` means a package failed to apply to at least one edition and that ISO is genuinely under-patched.

## How This Was Built

Most of the code here was written with an AI model. That is worth saying plainly rather than leaving it to be guessed at, because it changes the questions a reader should ask.

What it does not mean is that it was left to run on its own. Every line was reviewed and every path was tested by hand on real media, by someone with twenty years in Windows IT who was writing PowerShell long before any of this was available. No autopilot, no accepting a diff because it looked plausible, and nothing shipped that had not actually been run.

The design is mine. Even on the strongest models available, the concepts and the methods came first, from experience, and the model wrote against them. That distinction turned out to be the whole difference. Handed a goal and left to work out the approach, the models I tried stalled, went in circles or produced something confidently wrong. Handed a decided approach, they were genuinely quick at turning it into working code.

The parts of this script that matter most are the ones that came from knowing the terrain rather than from a model:

- The already-patched check is **deliberately asymmetric** and fails open, because a wrong skip silently ships an unpatched ISO. A model optimising for a clean-looking implementation trusts the WIM header and moves on.
- `Test-RebuildNeeded` runs **before** extraction, since a check that costs an hour of extraction is not a check worth having on a schedule.
- Monthly scheduled triggers are registered through exported XML, because the obvious `Register-ScheduledTask -Trigger` route returns `0x80070057` on client Windows no matter what you set.
- Windows PowerShell 5.1 is the target throughout, which rules out a long list of syntax and a few overloads that look correct and refuse to bind.

None of those came out of a prompt. They came out of having been bitten before, and the reason they are written down here is so the next person does not have to be.
