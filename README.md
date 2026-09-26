# Windows ISO Updater

Automate the process of updating Windows installation media. This PowerShell script takes an official Microsoft ISO, slipstreams the latest cumulative updates directly into the Windows image using DISM, and generates a fresh, fully patched bootable ISO. 

Installing Windows from this updated media saves time by eliminating large post-installation update downloads.

## Key Features

* **Safe Execution**: All operations occur within an isolated temporary directory (`C:\WISO-Work` by default). The host system configuration remains untouched.
* **No Manual ADK Setup Needed**: Automatically fetches a verified copy of `oscdimg.exe` from Microsoft servers to compile the media.
* **Official Sources Only**: Downloads packages directly from Microsoft endpoints over HTTPS.
* **Windows Server Support**: Compatible with Windows Server media using the `-Server` flag.

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
.\Run-Windows-ISO-Updater.bat -Server -IsoPath "C:\ISOs\Server2025.iso"
```

---

## Technical Considerations: Local Storage vs Network / Cloud Paths

* **Local Disk Requirement**: DISM mounting routines require local storage. Cloud-synced directories (OneDrive, Dropbox, Google Drive) introduce file-locking and sparse-file hydration issues that cause servicing errors, such as Unattend execution failures. Network shares (UNC paths and mapped drives) cannot host DISM scratch mounts.
* **Alternative Perspective**: Storing source media and finished builds on remote network shares remains practical for pipeline workflows. The script accommodates this by copying a remote source ISO to a local working path before servicing, then uploading the finished image back to the remote target.
* **Outcome**: Servicing operations will fail unless the primary working directory (`-WorkPath`) resides on a physical local disk. Keep the working directory local, and limit network paths strictly to input sources and final output destinations.

---

## Technical Considerations: Secure Boot and Media Creation

* **Stock Media Integrity**: The script produces standard ISOs preserving official Microsoft signatures. These boot cleanly under standard UEFI Secure Boot policies.
* **Alternative Perspective**: Tools like Rufus provide deployment conveniences, such as injecting `autounattend.xml` or bypassing TPM hardware checks.
* **Outcome**: Modifying installation binaries or loader paths invalidates the Microsoft signature chain. If a target machine enforces strict Secure Boot validation, use standard media flashing without third-party bypasses to prevent boot rejections.

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