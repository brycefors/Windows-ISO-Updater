[← Back to the README](../README.md)

# Unattended Installs

Pass an answer file with `-UnattendPath` and it is copied to the root of the finished ISO as `autounattend.xml`:

```shell
.\Run-Windows-ISO-Updater.bat -UnattendPath "C:\Answer\autounattend.xml"
```

Windows Setup implicitly reads `\autounattend.xml` from the root of read-only boot media during the `windowsPE` pass, so nothing else is needed. Boot the ISO and Setup runs without prompting. Generate the file with [Windows System Image Manager](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/wsim/windows-system-image-manager-technical-reference) (part of the ADK) or a generator such as [schneegans.de/windows/unattend-generator](https://schneegans.de/windows/unattend-generator/).

The script validates that the file exists and is well-formed XML before starting the build, and warns if the root element is not `<unattend>`.

> [!WARNING]
> Two things to watch for with any answer file:
> - **Edition selection.** By default this script drops the editions it is not keeping and renumbers `install.wim`, so an answer file that selects the edition with `/IMAGE/INDEX` will point at the wrong image. The default keeps the highest edition at index 1 (Enterprise, then Pro, then Home, in that order), so index 1 still means what it used to, but `/IMAGE/NAME` is the safer choice. Use it, or build with `-KeepAllEditions`. The script warns when it detects this combination.
> - **Secrets.** Answer files store passwords in plain text or base64 and product keys in the clear. Anyone who can read the ISO can recover them, so treat the finished ISO as a secret and don't commit the answer file to source control.

Three of the files in [`Examples/`](../Examples) are built around this workflow. [`autounattend-lab-admin.xml`](../Examples/autounattend-lab-admin.xml) and [`autounattend-gold-image.xml`](../Examples/autounattend-gold-image.xml) are a matched pair: one deploys a ready-to-use machine, the other builds an image to deploy *from*. [`autounattend-ultimate.xml`](../Examples/autounattend-ultimate.xml) is a more automated variant of the lab machine file, with the disk-wipe confirmation removed and driver installation dispatched by manufacturer. All three were produced with [schneegans.de/windows/unattend-generator](https://schneegans.de/windows/unattend-generator/) and then **hand edited**, and a comment at the top of each records exactly what was changed and why. The generator URL preserved alongside them reproduces the original options only, so regenerating from it discards the manual changes.

## Example: lab machine with no OOBE

[`Examples/autounattend-lab-admin.xml`](../Examples/autounattend-lab-admin.xml) skips OOBE entirely, signs in automatically as the built-in Administrator (password `Password123`), enables Remote Desktop, and sets `PreventDeviceEncryption` **only when the install detects it is running in a virtual machine**, because encrypted guests defeat block-level deduplication on the SAN, and it also stops Windows 11 24H2 silently turning on BitLocker there. On physical machines it **removes** that value rather than merely leaving it unset, so hardware deployed from a gold image that baked it in still encrypts normally. On VMware guests it also installs VMware Tools at first logon, using a Tools ISO mounted by the hypervisor if one is present and downloading from `packages.vmware.com` otherwise.

```shell
.\Run-Windows-ISO-Updater.bat -UnattendPath ".\Examples\autounattend-lab-admin.xml"
```

> [!CAUTION]
> That example produces a deliberately insecure machine: a well-known Administrator password stored in plain text in the answer file and on the finished ISO, an automatic first sign-in as Administrator, Remote Desktop reachable on all firewall profiles, and a first boot that downloads and silently runs an installer from the internet. It is for throwaway VMs on a trusted network only. Change the password in both places in the file, and never reuse it anywhere that matters.

> [!WARNING]
> **This example partitions and formats disk 0 without asking which disk to use.** A generated WinPE script first asserts that disk 0 exists and is between 100 and 4000 GiB, aborting if not. If disk 0 is **empty it proceeds with no prompt at all**, cleaning, partitioning, applying image index 1 and rebooting. If disk 0 **already holds partitions** it stops and asks: you must type `WIPE` to erase it, and any other answer aborts without touching the disk.
>
> Because it applies **index 1**, it pairs with the default edition handling, which puts the highest edition at index 1 (Enterprise if the media has it, otherwise Pro), with the remaining kept editions after it. If you build with `-KeepAllEditions`, index 1 is whichever edition came first in the original ISO, usually Home rather than the one you probably want.

## Example: gold image build

[`Examples/autounattend-gold-image.xml`](../Examples/autounattend-gold-image.xml) builds a **reference machine** that you customize by hand, seal with `sysprep /generalize`, and capture, rather than a machine that is ready to use. It uses the same windowsPE installer as the lab example, so **disk 0 is wiped and image index 1 applied on the same terms** (no prompt on an empty disk, type `WIPE` on one that already holds partitions). The differences are all in what happens after Windows is on disk:

- **Almost no hardware-conditional logic.** The `specialize` pass runs once, on the reference machine, so the lab file's `$isVirtualMachine` branches would stamp the *build* machine's identity onto every target. The one surviving branch is the idle timeout block, which only keeps a virtual reference machine awake while you work on it. The active power scheme is never changed, so nothing forces High Performance onto a laptop, and the lab answer file restores the default schemes on physical targets.
- **`PreventDeviceEncryption` is a build-only setting.** BitLocker on the volume you are about to capture breaks the capture, so `specialize` sets it whatever the reference machine is, and the seal checklist has you **delete it again before running sysprep**. Because `specialize` runs once, on the reference machine, it cannot make this decision per target, so the image ships neutral and the deployment answer file decides. The lab file sets it on VMs, where encrypted guests defeat block-level deduplication on the SAN, and leaves physical hardware to encrypt normally. Shipping it neutral also fails in the safe direction: an answer file that never considers the question leaves a physical machine encrypting, rather than a fleet that silently never encrypts.
- **The answer file deletes itself** from `C:\Windows\Panther` at first logon. `sysprep /generalize` implicitly consumes `Panther\unattend.xml`, so leaving it there would re-run the `specialize` pass, and carry the plain-text password, onto every machine deployed from the captured image.
- **8.3 short file names are left enabled.** The lab file disables them on the target volume and in the offline `SYSTEM` hive, which is dropped here so installers that still resolve short paths work while you build the image.
- **`C:\Windows.old` is removed properly.** The lab file's plain `rmdir` only deletes an empty directory, so this takes ownership and grants Administrators full control first. Skipped when the folder is absent, which is the normal case on a wiped disk.
- **No `CopyProfile`, no product key, no domain join, no vendor drivers.** All machine- or site-specific, and `CopyProfile` is the usual reason a gold image ships with a broken Start menu.

It drops a `SEAL-THIS-IMAGE.txt` checklist on the public desktop with the remaining manual steps, including the seal command:

```shell
%WINDIR%\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown
```

```shell
.\Run-Windows-ISO-Updater.bat -UnattendPath ".\Examples\autounattend-gold-image.xml"
```

> [!TIP]
> Finish your customization **offline**. Windows Update refreshing an inbox app for the signed-in user is the usual cause of sysprep failing with `SYSPRP Failed to remove apps for the current user: 0x80073CF2`, and when it happens, `C:\Windows\System32\Sysprep\Panther\setupact.log` names the package. The same applies to the VMware Tools download fallback, which also makes the build non-reproducible, so attach the hypervisor's Tools ISO instead if you want a fixed version.

> [!CAUTION]
> This example uses the same plain-text `Password123` build credential and automatic first sign-in as the lab example. `sysprep /oobe` disables the built-in Administrator, but its hash survives generalize, so anything that later re-enables the account without setting a new password inherits it. Change it before you build anything you intend to keep.

## Example: fully unattended deployment

[`Examples/autounattend-ultimate.xml`](../Examples/autounattend-ultimate.xml) is `autounattend-lab-admin.xml` with the disk-wipe confirmation removed and driver installation dispatched by manufacturer. Unlike that file, it defines no local account and signs no one in automatically. `<AutoLogon>`, the `<UserAccounts><AdministratorPassword>` block, and the OOBE-suppression flags are all gone, so Windows Setup's normal account-creation and network check-in phase runs instead of being skipped. That is the phase where a device enrolled in Windows Autopilot detects itself, downloads its profile, and joins Entra ID at first boot, so enrolled hardware still ends up fully configured with no one at the console. It carries forward that file's windowsPE installer and BitLocker/power handling unchanged apart from the differences noted below.

```shell
.\Run-Windows-ISO-Updater.bat -UnattendPath ".\Examples\autounattend-ultimate.xml"
```

> [!CAUTION]
> On hardware that is **not** Autopilot-enrolled, removing the automatic sign-in means a person has to complete OOBE's account-creation screens by hand before they can sign in and use the machine. Driver dispatch, VMware Tools install, and `Windows.old` cleanup no longer wait on that, they run unconditionally during specialize regardless of whether or when a person or Autopilot completes OOBE. Remote Desktop is still reachable on all firewall profiles here, same as `autounattend-lab-admin.xml`.

Seven things differ from the lab example:

- **8.3 short file names are left enabled, same as `autounattend-gold-image.xml`.** The lab file disables them on the target volume and in the offline `SYSTEM` hive. This file drops those two steps for the same reason as the gold image, some installers still resolve short paths.
- **No disk-wipe confirmation, ever.** The lab file's WinPE installer stops and asks you to type `WIPE` before erasing a disk 0 that already holds partitions. This file removes that prompt entirely, so an already-partitioned disk 0 is wiped exactly like an empty one, with no keypress and no chance to abort.
- **Hardcodes image index 1**, same as the lab example, so it carries the same precondition: the source ISO must have been built with this script's default edition-keep behavior, which drops every edition but the single highest ranked one (Enterprise, then Pro, then Home) and renumbers it to index 1. Pairing it with an ISO built using `-KeepAllEditions` or a narrowed `-KeepEditions`/`-Edition` selection can leave index 1 pointing at something other than the highest edition, and Setup applies whatever is there with no warning.
- **Dispatches driver installation by manufacturer instead of a pre-staged `C:\Drivers\` folder.** During specialize, before anyone can sign in, it checks `Win32_ComputerSystem.Manufacturer` and calls `tools/Install-DellDrivers.ps1` on Dell hardware or `tools/Install-SurfaceDrivers.ps1` on Microsoft/Surface hardware, both embedded verbatim, or logs an informational line and calls neither script on any other manufacturer, including VMs. The call is direct and synchronous rather than an async `Start-Process` window, since specialize has no interactive desktop to show a window on.
- **Password expiration and the suggested-apps CloudContent policy are left at their defaults.** Unlike `autounattend-lab-admin.xml`, this file does not run the unlimited-password-age command (`net.exe accounts /maxpwage:UNLIMITED`) and does not write the CloudContent registry values that block suggested app installs, for a more vanilla default Windows 11 result.
- **No `<AutoLogon>`, no built-in Administrator password, and none of the OOBE-suppression flags.** The lab file signs in automatically as the built-in Administrator and skips OOBE outright. This file removes `<AutoLogon>`, the `<UserAccounts><AdministratorPassword>` block, and `ProtectYourPC`, `HideEULAPage`, and `HideWirelessSetupInOOBE` from `<OOBE>`, so Windows Setup's normal account-creation and network check-in phase runs, letting Windows Autopilot check in and apply its profile on enrolled hardware but requiring a person to complete OOBE by hand on hardware that is not Autopilot-enrolled first.
- **`FirstLogonCommands` and `FirstLogon.ps1` no longer exist.** The lab example still runs driver dispatch, VMware Tools install, and `Windows.old` cleanup from `FirstLogonCommands` at first logon. This file folds that same work into `Specialize.ps1`'s script list instead, so it is unconditional and no longer depends on anyone reaching first logon at all. `tools/Install-DellDrivers.ps1` and `tools/Install-SurfaceDrivers.ps1` also gained retry loops of about three minutes on their initial network fetches, matching the existing `VMwareTools.ps1` pattern, since specialize can start before DHCP settles.

> [!CAUTION]
> **This example wipes disk 0 with no confirmation prompt at all**, even if the disk already holds partitions. That is strictly more dangerous than `autounattend-lab-admin.xml`, whose default behavior requires typing `WIPE` before an already-partitioned disk 0 is erased. There is no such safety net here. Point this file at the wrong machine and the disk is gone with no chance to abort. Use it only on hardware or VMs you have already confirmed are disposable.

> [!WARNING]
> Because it applies **index 1** with no prompt, this file must be paired with an ISO built using this script's default edition handling. Do not use it with `-KeepAllEditions` or a narrowed `-KeepEditions`/`-Edition` selection, either one can leave index 1 pointing at something other than the highest edition, with nothing to catch the mismatch before the disk is wiped.

## Model-based driver install

The lab-admin answer file (`autounattend-lab-admin.xml`) runs `Install-ModelDrivers.ps1` as a hidden background process at first logon, started by `FirstLogon.ps1`.

### What it does

The script reads `Win32_ComputerSystem.Model`, looks for a subfolder under `C:\Drivers\` whose name is a substring of that model string, installs any `.msi` packages in that folder silently with no reboot, then stages any loose `.inf` files via `pnputil /add-driver /install`. It logs to `C:\Windows\Setup\Scripts\Install-ModelDrivers.log` and removes `C:\Drivers\` when done.

### Why not inject the drivers into the WIM

Injecting drivers into the WIM with DISM makes the WIM hardware-specific. This approach keeps the WIM hardware-neutral: each machine picks up only the drivers in the folder that matches its model, and different machines served from the same ISO get only their own packages.

### Folder structure

Driver packages go into `$OEM$\$1\Drivers\<Model Name>\` at the root of the ISO, at the same level as `sources\`, `boot\`, and `efi\`. Windows Setup copies `$OEM$\$1\` to `C:\` automatically, so the packages land at `C:\Drivers\<Model Name>\`.

Use the exact string that `(Get-CimInstance Win32_ComputerSystem).Model` returns on the target hardware as the folder name. A folder named `Surface Pro 9` matches any model whose reported name contains that string, so partial names work when the full string varies across firmware revisions.

```
<ISO root>\
  $OEM$\
    $1\
      Drivers\
        Surface Pro 9\
          SurfaceProDrivers.msi
        Surface Laptop 5\
          SurfaceLaptopDrivers.msi
  boot\
  efi\
  sources\
```

Run this on the target hardware before building the ISO to get the exact model string:

```powershell
(Get-CimInstance Win32_ComputerSystem).Model
```

### MSI vs INF

If the vendor ships a `.msi` driver pack, place the `.msi` directly in the model folder. Surface driver packs are published at [microsoft.com/en-us/download/search/?q=surface+drivers](https://www.microsoft.com/en-us/download/search/?q=surface+drivers).

For hardware where only `.inf` files are available, place them and any supporting files (in subfolders if needed) in the model folder and `pnputil` will recurse into subdirectories.

### Gold image

`autounattend-gold-image.xml` does not include this script. The gold image is sysprepped and captured before deployment, and model-specific drivers installed before capture would be baked into the image and applied to every machine deployed from it. This feature belongs only in the deployment answer file.

### Fully unattended deployment

`autounattend-ultimate.xml` does not include this script either. It dispatches on `Win32_ComputerSystem.Manufacturer` instead of a pre-staged `C:\Drivers\` folder, calling `tools/Install-DellDrivers.ps1` or `tools/Install-SurfaceDrivers.ps1` during specialize. See [Example: fully unattended deployment](#example-fully-unattended-deployment) above.

### Logging and cleanup

The log is at `C:\Windows\Setup\Scripts\Install-ModelDrivers.log`. `C:\Drivers\` is deleted after a successful install.

### Adding models without rebuilding

The `$OEM$` folder lives in the ISO file structure outside the WIM. Adding or updating model folders does not affect any WIM content, so you can re-populate `$OEM$` and rebuild the ISO without re-servicing the images. The rebuild-avoidance stamp is not affected.

[← Back to the README](../README.md)
