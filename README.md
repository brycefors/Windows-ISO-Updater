# Windows ISO Updater

Automate the process of updating Windows installation media. This PowerShell script takes an official Microsoft ISO, slipstreams the latest cumulative updates directly into the Windows image using DISM, and generates a fresh, fully patched bootable ISO. 

Installing Windows from this updated media saves time by eliminating large post-installation update downloads.

## Key Features

* **Safe Execution**: All operations occur within an isolated temporary directory (`C:\WISO-Work` by default). The host system configuration remains untouched.
* **No Manual ADK Setup Needed**: Automatically fetches a verified copy of `oscdimg.exe` from Microsoft servers to compile the media.
* **Official Sources Only**: Downloads packages directly from Microsoft endpoints over HTTPS.
* **Windows Server Support**: Compatible with Windows Server media, detected automatically from the image.

---

## Quick Start

1. Place `Run-Windows-ISO-Updater.bat` and `Windows-ISO-Updater.ps1` in the same directory.
2. Put an official Windows ISO in `C:\WISO-Work\Downloads` or specify its location with `-IsoPath`.
3. Right-click `Run-Windows-ISO-Updater.bat` and select **Run as administrator**.
4. Confirm the build settings displayed in the console prompt.

### Command Examples

**Unattended Custom Build:**
```shell
.\Run-Windows-ISO-Updater.bat -IsoPath "C:\ISOs\Win11.iso" -Edition "Windows 11 Pro" -Unattended
```

**Windows Server Build:**
```shell
.\Run-Windows-ISO-Updater.bat -IsoPath "C:\ISOs\Server2025.iso"
```

---

## Where to Keep the Working Folder

DISM services an image by projecting it onto a folder, and that only works on a real local disk. Cloud-synced
folders (OneDrive, Dropbox, Google Drive) hand back placeholder files that the sync client rehydrates on
demand, which surfaces as servicing errors partway through a build. Network shares and mapped drives cannot
host a DISM mount at all.

Source media and finished ISOs are a different matter, and those are fine on a share. The script copies a
remote source ISO to local disk before it mounts anything, then copies the finished ISO back out to the
remote path at the end.

So keep `-WorkPath` on a local disk, and save the network paths for `-IsoPath` and `-OutputIsoPath`.

---

## Secure Boot

The ISO this script produces is stock media with Microsoft's boot files and signatures untouched, so it boots
on a machine with Secure Boot enabled without any extra steps.

Keep it that way when you write it to a USB stick. Flashing the ISO as it is preserves the signed boot loader,
while anything that swaps in its own loader or patches the installer binaries breaks the signature chain, and
a machine enforcing Secure Boot will refuse it. If you want an answer file on the media, use `-UnattendPath`
so it goes on before the ISO is built rather than being added afterwards.

---

## Requirements

* Windows 10, Windows Server 2016, or newer
* PowerShell 5.1 or newer
* Administrator permissions
* Active internet connection for update retrieval
* Sufficient local storage space (at least 30 GB free recommended)

---

## Documentation Links

* [Usage Guide](docs/usage.md)
* [Command-Line Parameters](docs/parameters.md)
* [Scheduled Automation](docs/scheduled-runs.md)
* [Unattended Setups](docs/unattended-installs.md)
* [Architecture and Design Details](docs/design-notes.md)
* [Technical Reference](docs/reference.md)

## License

Distributed under the [MIT License](LICENSE). Third-party utilities and Microsoft updates fetched during runtime remain governed by their respective vendor terms.