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
> - **Edition selection.** By default this script keeps only one edition and renumbers `install.wim`, so an answer file that selects the edition with `/IMAGE/INDEX` will point at the wrong image. Use `/IMAGE/NAME` instead, or build with `-KeepAllEditions`. The script warns when it detects this combination.
> - **Secrets.** Answer files store passwords in plain text or base64 and product keys in the clear. Anyone who can read the ISO can recover them, so treat the finished ISO as a secret and don't commit the answer file to source control.

The two files in [`Examples/`](../Examples) are a matched pair: one deploys a ready-to-use machine, the other builds an image to deploy *from*. Both were produced with [schneegans.de/windows/unattend-generator](https://schneegans.de/windows/unattend-generator/) and then **hand edited**, and a comment at the top of each records exactly what was changed and why. The generator URL preserved alongside them reproduces the original options only, so regenerating from it discards the manual changes.

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
> Because it applies **index 1**, it pairs with the default edition handling, which leaves a single edition at index 1. If you build with `-KeepAllEditions`, index 1 is whichever edition came first in the original ISO, usually Home rather than the one you probably want.

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
