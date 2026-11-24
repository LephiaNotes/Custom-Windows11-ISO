# Custom-Windows11-ISO

Toolkit to customize your own Windows 11 installation by modifying the official ISO. It doesn't tamper with the requirement for the OS to be activated. It creates a local account named "Renmiri", then disables most bloat and telemetry services.

It turns an official Microsoft Windows 11 ISO into a general-purpose ISO for any PC. The ISO installs like a Rufus-customized USB, works from **Ventoy**, Rufus or a VM, bundles your apps for an offline install, and removes Copilot and OneDrive.

## What you get

| Area | What the ISO does |
|---|---|
| **Rufus-style install** | Skips the TPM 2.0, Secure Boot, RAM, storage and CPU checks. No Microsoft account or internet is required. A local admin account is created, and the EULA, OEM, account and privacy pages are skipped. Automatic BitLocker device encryption is turned off. You still pick the language and the disk yourself, so nothing gets wiped without you choosing it. |
| **Bloat removed** | Copilot, Dev Home, Clipchamp, News, Weather, Bing Search, Get Started, Office Hub, Solitaire, new Outlook, People, Power Automate, To Do, Feedback Hub, Maps, Teams, Phone Link, Quick Assist and Family. The Xbox apps and Game Bar are **kept** for gaming. You can edit the list in `config/remove-apps.txt`. |
| **Telemetry** | Telemetry is set to the lowest level your edition allows. The DiagTrack and dmwappushservice services are disabled. CEIP, error reporting, the advertising ID, activity history, "tailored experiences", inking/typing data collection and feedback prompts are all turned off. |
| **Copilot / AI** | The Copilot app is removed, its policies are turned off, and the taskbar button is hidden. Recall is disabled, along with AI data analysis and Click to Do. The Copilot sidebar in Edge is turned off. |
| **OneDrive** | The installer is deleted from the image, it no longer runs for new users, sync is blocked by policy, and it is hidden from the Explorer sidebar. |
| **Ads and nags** | Start suggestions, silently installed apps, lock-screen tips, widgets, the Chat icon, Bing results in Start search and the "Let's finish setting up" screen are all turned off. Peer-to-peer update sharing is off too. |
| **Your apps** | **Bundled inside the ISO** and installed at first sign-in without internet: Steam and League of Legends (SEA server) on your **Games** drive, plus VLC, MSI Afterburner, RivaTuner, Git, Obsidian, WinRAR, Discord and the VC++ runtime. The build downloads these for you. Steam, League and Discord are small launchers, so they download the rest when you first open them. |
| **Drivers** | None are bundled, so the ISO works on any PC. **Windows Update does not install drivers**, because you install them yourself. Windows' built-in drivers still work. Device companion apps (Adrenalin, Realtek Audio Console and so on) aren't auto-installed either. `drivers/` is there if a PC ever needs a driver built in, for example a network card Windows doesn't recognise. |

## What you need

- A Windows 10 or 11 PC with **winget** (built in on Windows 11), an admin PowerShell and internet. The build downloads the app installers.
- About 30 GB of free disk space.
- The **official Windows 11 ISO** from <https://www.microsoft.com/software-download/windows11>. Use the "Download Windows 11 Disk Image (ISO)" option.
- **oscdimg** from the Windows ADK, to build the ISO. Install it with:
  ```powershell
  winget install --id Microsoft.WindowsADK -e
  ```
  When the installer asks, tick only **Deployment Tools**.

## Build it

1. **Optional extras:** both folders start empty, and their READMEs explain how to use them.
   - `drivers/`: drivers to build into the image.
   - `offline-installers/`: installers that aren't on winget.
2. **The second drive is found automatically**, so there's nothing to prepare. At first sign-in, Steam and League go to `Games\Steam` and `Games\Riot Games` on the new PC's second drive:
   - If a drive is labelled "Gaming Drive", that one is used.
   - Otherwise the largest internal NTFS drive other than C: is used. USB sticks and SD cards are skipped, and the chosen drive gets labelled "Gaming Drive". If there are several, the largest wins and the log lists the others.
   - If there's no second drive, or it's brand new and was never formatted, they install to their normal folders on C:. To avoid that with a new drive, format it during Windows Setup's disk screen (select it, then New, then Format).
   - `FirstLogon.log` shows which drive was picked. The League installer has no folder option for scripts, so its window opens at first sign-in. The folder to pick is shown and already copied to the clipboard.
3. Edit `config/apps.txt` (the apps to bundle) and `config/remove-apps.txt` (the apps to remove). The build downloads the installer of every app in the list and puts it inside the ISO.
   - To choose where an app installs, add `| folder` after its ID, e.g. `VideoLAN.VLC | D:\Apps\VLC`.
   - For a second drive, prefer its **volume label**: `Valve.Steam | {Gaming Drive}\Games\Steam` installs on the drive labelled "Gaming Drive", or else on the second internal drive (see step 2). The drive must be connected when Windows is installed.
   - Most installers honor the folder. Store/MSIX apps ignore it. If a drive isn't found, that app goes to its normal folder and the log says so.
4. The local account is named **Renmiri** by default (change it with `-UserName`). Open **PowerShell as administrator** in this folder and run:
   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass -Force
   .\Build-CustomISO.ps1 -SourceIso "C:\Users\You\Downloads\Win11_25H2_English_x64.iso" -UserName Renmiri
   ```
   Useful options:
   - `-Edition "Windows 11 Home"`: the script lists the editions it finds. The default is Pro.
   - `-NoPrompt`: no "Press any key to boot from CD/DVD" prompt. Handy for VMs.
   - `-CleanupComponents`: makes the ISO smaller, but adds 15 to 40 minutes.
   - `-PreventDeviceEncryption $false`: keeps Windows' automatic BitLocker.
   - `-WorkDir D:\Build -OutputIso D:\Win11-Custom.iso`. Avoid spaces in these paths.
   - `-RefreshDownloads`: fetches the newest app installers again. Otherwise the cached copies in `<WorkDir>\downloads` are reused, which makes rebuilds faster.
   - `-NoAppDownload`: doesn't bundle the apps. They install online at first sign-in instead.
5. The build takes about 20 to 40 minutes. The ISO is written to `C:\Win11Build\Win11-Custom-<date>.iso`. Check the "Downloading app installers" part of the output. Any app it couldn't bundle is listed there and gets installed online instead.

## Install it

- **Test in a VM first**, for example in Hyper-V or VirtualBox. It's the quickest way to check your app list.
- **Ventoy (your setup):** copy the ISO onto the Ventoy USB stick and boot it. Nothing else is needed:
  - The TPM / Secure Boot / RAM / CPU bypass is built into the installer itself (boot.wim), and Ventoy also applies it by default.
  - The answer file is in the ISO root **and** inside Windows (`C:\Windows\System32\Sysprep\unattend.xml`). So the local account, the skipped setup pages and the first-sign-in app install happen even if Setup doesn't read the ISO root file under Ventoy.
  - The ISO can be larger than 4 GB, and Ventoy handles that fine.
  - Leave Ventoy's `auto_install` plugin **off** for this ISO, because the ISO carries its own answer file.
  - If the PC has Secure Boot on and Ventoy shows a "Verification failed" screen, enroll Ventoy's key once (see Ventoy's Secure Boot guide) or turn Secure Boot off while installing.
- **Rufus instead:** write the ISO with GPT / UEFI. When Rufus shows its "Customize Windows installation?" dialog, untick everything, because those options are already inside.
- Boot from the USB stick and choose your language. When asked for a product key, click **"I don't have a product key"**. If the PC had Windows 10/11 before, it activates on its own with its digital license. Then pick the disk.
- **Apps don't need internet**: bundled apps install offline, and only apps that failed to bundle need it.  After the first sign-in, a PowerShell window installs everything. One installer opens its own window for you to click through:
  - **League of Legends** opens first. Click the folder / "Advanced options" link, paste with Ctrl+V (the Games path is already copied), then click Install. It downloads the game itself in the background once you're online.
  - Leave everything else alone until the window closes. The log is saved at `C:\Windows\Setup\Scripts\FirstLogon.log`.
- The account starts with **no password**. Windows asks you to set one at your next sign-in.

## Safety notes

**Windows Update, the Microsoft Store, winget and Defender all keep working.** The build script and first-logon script refuse to remove the Store, App Installer (winget), Windows Security, Terminal, Notepad or the runtime libraries, even if they appear in the remove list.

Some changes have side effects:

- **Windows Update doesn't install drivers** (`tweaks/31-no-wu-drivers.reg`), and companion apps aren't auto-installed (`tweaks/30-no-device-apps.reg`). After setup, install the GPU, chipset and other drivers from the makers' sites. If a PC's network card has no built-in Windows driver, it won't get online until you install that driver (from a USB stick, or put it in `drivers/` before building). To let Windows Update handle drivers again, delete `31-no-wu-drivers.reg` before building, or run `Revert-Tweaks.ps1 -Only Drivers` on the PC.
- **If you remove the Xbox apps later**, copy `tweaks/optional/gamebar-off.reg` into `tweaks/` before building, so you don't get the "ms-gamebar link" pop-up.
- **OneDrive sync blocked by policy:** if you want OneDrive later, run `Revert-Tweaks.ps1 -Only OneDrive` and then `winget install Microsoft.OneDrive`.
- **Error reporting off:** crash reports are no longer sent to Microsoft or app vendors.
- **Telemetry "0" on Home/Pro:** Windows treats this as "Required diagnostic data". That's the minimum Microsoft allows outside Enterprise/Education. Nothing on Home/Pro gets telemetry to zero without breaking things.
- **Bypassing the TPM/CPU checks:** Microsoft says unsupported PCs may not get every update. In practice, monthly updates install normally. A big yearly feature update may need the same ISO trick again.
- **Feature updates:** some removed apps or settings may come back after a yearly feature update. Re-running `FirstLogon.ps1` removes the apps again.

**Deliberately not changed,** because these break things:

- Edge and WebView2 are not removed. Widgets, Help, and many apps need WebView2.
- The Windows Update, BITS, Store install, licensing (ClipSVC) and Microsoft account sign-in services are not touched.
- Defender is not disabled.

**Undo** on an installed PC: run `.\Revert-Tweaks.ps1` as admin, or `-Only Telemetry|Copilot|OneDrive|Ads|Services|DeliveryOptimization|GameBar|Drivers`, then restart. Removed apps can be reinstalled from the Microsoft Store.

## Files

```
Build-CustomISO.ps1        builds the ISO (run this)
autounattend.xml           answer file: TPM/RAM bypass, local account, skipped setup pages (__USERNAME__ filled in by the build)
config/apps.txt            winget IDs installed at first sign-in
config/remove-apps.txt     preinstalled apps removed from the image
tweaks/10-machine.reg      telemetry, Copilot, OneDrive, ads, services (machine-wide)
tweaks/20-default-user.reg the same for every new user profile
tweaks/30-no-device-apps.reg  stops auto-installed device companion apps (drivers still install)
tweaks/31-no-wu-drivers.reg   Windows Update doesn't install drivers
scripts/FirstLogon.ps1     runs once at first sign-in: apps, OneDrive cleanup
offline-installers/        optional .exe/.msi installers plus installers.csv (empty)
drivers/                   optional extracted driver folders (.inf) built into the image (empty)
tweaks/optional/           .reg files NOT imported unless you move them up
Revert-Tweaks.ps1          undoes the tweaks on an installed PC
```

Add your own `.reg` file to `tweaks/` and it is imported too. Write its keys as `HKEY_LOCAL_MACHINE\WIM_SOFTWARE\...`, `WIM_SYSTEM\ControlSet001\...` or `WIM_DEFAULT\...` for per-user settings.
