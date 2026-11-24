# Custom-Windows11-ISO

Toolkit to customize your own Windows 11 installation by modifying the official ISO. It turns Microsoft's ISO into one that installs without a Microsoft account, without bloat and with less telemetry, with your apps already in place at first sign-in. It doesn't tamper with activation, so Windows still activates normally. The ISO is generic and works on any PC.

## What it does

- **Rufus-style install:** skips the TPM, Secure Boot, RAM and CPU checks. It creates a local account named **Renmiri** with no password (Windows asks for one at the next sign-in), skips the privacy screens and keeps BitLocker off.
- **Bloat removed:** Copilot, Recall, OneDrive, Teams, Widgets, News, Weather, Clipchamp, the new Outlook, and ads and suggestions. The Xbox apps and Game Bar are kept.
- **Less telemetry:** the tracking services are disabled and data collection is set as low as the edition allows. On Home and Pro that's "Required", not zero.
- **Drivers left to you:** Windows Update doesn't install drivers or companion apps like Adrenalin or Realtek Audio Console. Install the GPU, chipset and motherboard drivers manually.
- **Apps installed offline:** Steam, League of Legends (SEA), VLC, MSI Afterburner, RivaTuner, Git, Obsidian, WinRAR and Discord. The build downloads their installers and puts them inside the ISO.
- **Games on the second drive:** the second drive is detected, named **Gaming Drive**, and Steam and League are installed in a `Games` folder on it.

## Requirements

- A Windows PC with admin rights, internet and about 30 GB free.
- The official Windows 11 ISO: https://www.microsoft.com/software-download/windows11
- Microsoft's ISO build tool. Run `winget install --id Microsoft.WindowsADK -e` and tick only **Deployment Tools**.

## Building the ISO

1. Download or clone this repo to a folder **without spaces**, such as `C:\Custom-Windows11-ISO`.
2. (Optional) Edit the app list in `config\apps.txt`. It takes one winget ID per line. Find IDs with `winget search <name>`, and put `#` in front of a line to skip it.
3. Open PowerShell **as administrator** in that folder and run:
   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass -Force
   .\Build-CustomISO.ps1 -SourceIso "C:\path\to\Win11.iso"
   ```
4. The build takes 20 to 40 minutes. The ISO is saved in `C:\Win11Build`.

In the output, every tweak file should report **0 failed** and every app should report **bundled**.

Useful options:
- `-UserName Name`: a different account name.
- `-Edition "Windows 11 Home"`: a different edition. The default is Pro.
- `-RefreshDownloads`: downloads the newest app installers instead of reusing the cached ones.

## Installing

1. Copy the ISO onto a **Ventoy** USB stick and boot from it. Leave Ventoy's auto-install plugin off, because the ISO already has its own settings. Rufus also works if its customization options are unticked.
2. At the product key screen, click **I don't have a product key**.
3. Choose the disk to install to. A brand-new games drive must be formatted here, or it won't be used.
4. After the first sign-in, a PowerShell window installs the apps. Let it finish. The only step that needs input is League's installer: choose the folder option, press **Ctrl+V** (the path is already copied), and click Install.
5. Install the drivers.

## Troubleshooting

- The log is at `C:\Windows\Setup\Scripts\FirstLogon.log`.
- If some apps didn't install, run `C:\Windows\Setup\Scripts\FirstLogon.ps1` again.
- To undo the tweaks, run `Revert-Tweaks.ps1` as admin and restart. A single area can be undone with options like `-Only OneDrive` or `-Only Drivers`.

## Notes

- Monthly updates install normally. A yearly feature update may bring back some apps or need this ISO again.
- Edge is kept, because many parts of Windows depend on it.
- Windows Update, the Microsoft Store and Defender keep working.
- The `drivers` and `offline-installers` folders each have a short guide for building in extra drivers or installers.
