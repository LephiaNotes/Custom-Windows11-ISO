Optional: drivers built straight into the image. Empty by default, so the ISO works on
any PC and Windows Update supplies drivers after setup.

Use it when a PC needs a driver BEFORE it can get online (e.g. a Wi-Fi card or network
port Windows doesn't recognise), or for a build meant for one specific machine.

How:
  - Make a subfolder per driver, e.g. drivers\WiFi\, and copy the EXTRACTED driver package
    into it (zip: extract it; exe: open with WinRAR / 7-Zip, or copy the folder next to
    setup.exe). The build searches all subfolders for .inf files and ignores setup.exe,
    readmes and tools.
  - The build reports "N driver(s) added" per folder, or warns if a folder has no .inf.
  - Drivers built in here are generic-safe: Windows only installs one if the PC has the
    matching hardware, so extra drivers don't hurt other PCs.

Tip: to grab the drivers of a PC that already runs Windows (admin PowerShell):
  Export-WindowsDriver -Online -Destination D:\ExportedDrivers
