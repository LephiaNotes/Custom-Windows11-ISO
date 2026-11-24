# Custom-Windows11-ISO

My toolkit for building my own Windows 11 ISO. It takes the official ISO from Microsoft and turns it into one that installs the way I like: no Microsoft account, no bloat, less telemetry, and my apps already there when I first sign in. It doesn't touch activation, so Windows still activates normally.

I made it generic so I can use it on any PC.

## What it does

- **Installs like a Rufus USB.** It skips the TPM, Secure Boot, RAM and CPU checks, creates a local account called **Renmiri** with no password (you set one at the next sign-in), skips the privacy screens and keeps BitLocker off.
- **Removes the junk.** Copilot, Recall, OneDrive, Teams, Widgets, News, Weather, Clipchamp, the new Outlook and the usual ads and suggestions are gone. I kept the Xbox apps and Game Bar because I game.
- **Cuts telemetry.** It turns off the tracking services and sets data collection as low as Windows allows. On Home and Pro that's "Required", not zero.
- **Leaves drivers to me.** Windows Update won't install drivers, and it won't sneak in apps like Adrenalin or Realtek Audio Console either. I install the GPU, chipset and motherboard drivers myself.
- **Installs my apps offline.** Steam, League of Legends (SEA), VLC, MSI Afterburner, RivaTuner, Git, Obsidian, WinRAR and Discord. The build downloads their installers and puts them inside the ISO.
- **Puts games on the second drive.** It finds the second drive, names it **Gaming Drive**, and installs Steam and League into a `Games` folder there.

## What you need

- A Windows PC with admin rights, internet and about 30 GB free.
- The official Windows 11 ISO: https://www.microsoft.com/software-download/windows11
- Microsoft's ISO build tool. Run `winget install --id Microsoft.WindowsADK -e` and tick only **Deployment Tools**.

## Building the ISO

1. Download or clone this repo to a folder **without spaces**, like `C:\Custom-Windows11-ISO`.
2. (Optional) Change the apps in `config\apps.txt`. Put one winget ID per line. You can find IDs with `winget search <name>`, and a `#` in front of a line skips it.
3. Open PowerShell **as administrator** in that folder and run:
   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass -Force
   .\Build-CustomISO.ps1 -SourceIso "C:\path\to\Win11.iso"
   ```
4. Wait 20 to 40 minutes. The ISO ends up in `C:\Win11Build`.

While it runs, check two things in the output: every tweak file should say **0 failed**, and every app should say **bundled**.

Handy options:
- `-UserName Name` uses a different account name.
- `-Edition "Windows 11 Home"` picks another edition. Pro is the default.
- `-RefreshDownloads` gets the newest app installers, because they're reused between builds otherwise.

## Installing

1. Copy the ISO onto a **Ventoy** stick and boot from it. Everything is already inside the ISO, so leave Ventoy's auto-install plugin off. Rufus works too: just untick its customization options.
2. When it asks for a product key, click **I don't have a product key**.
3. Pick the disk to install to. If the games drive is brand new, format it here, otherwise it won't get used.
4. After the first sign-in, a PowerShell window installs the apps. Let it finish. The only thing you need to click is League's installer: choose the folder option, press **Ctrl+V** (the path is already copied), and hit Install.
5. Install your drivers.

## If something goes wrong

- The log is at `C:\Windows\Setup\Scripts\FirstLogon.log`.
- If the apps didn't all install, run `C:\Windows\Setup\Scripts\FirstLogon.ps1` again.
- To undo the tweaks, run `Revert-Tweaks.ps1` as admin and restart. You can also undo one area at a time, like `-Only OneDrive` or `-Only Drivers`.

## Good to know

- Monthly updates install fine. A big yearly update might bring back some apps or need this ISO again.
- Edge stays, because a lot of Windows needs it under the hood.
- Windows Update, the Store and Defender all still work.
- If you ever want drivers or extra installers baked in, the `drivers` and `offline-installers` folders each have a short how-to.
