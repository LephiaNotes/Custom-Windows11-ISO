Optional: installers that are not on winget. They run at first sign-in, after the apps in
config\apps.txt, in the order listed in installers.csv. Empty by default.

How to add one:
  1. Make a subfolder here and put the installer in it (for multi-file installers, copy
     everything that belongs with it).
  2. Add a line to installers.csv:

     File,Arguments
     MyTool\MyTool-Setup.exe,/S
     SomeApp\SomeApp.msi,
     BigApp\BigApp*Installer.exe,

  File       path inside this folder; wildcards (*) are fine so version numbers don't matter
  Arguments  silent-install switches. Leave EMPTY for installers that must be clicked
             through: their window opens and the script waits for you.
  .msi files are always run with /qn /norestart.

A line whose file isn't here is skipped. Files here make the ISO bigger.
