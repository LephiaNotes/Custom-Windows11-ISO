<#
.SYNOPSIS
    Builds a customized, debloated Windows 11 ISO from an official Microsoft ISO.

.DESCRIPTION
    1. Copies the official ISO contents to a work folder.
    2. Exports the single edition you want (default: Windows 11 Pro) to a fresh install.wim.
    3. Mounts the image and:
         - removes the bloat apps listed in config\remove-apps.txt
         - adds every driver .inf found under drivers\ (DISM), so they install during Setup
         - disables Recall (optional feature) if present
         - imports the registry tweaks in tweaks\*.reg into the offline image
           (telemetry, Copilot, OneDrive, ads/suggestions, services)
         - copies scripts\ and config\ into C:\Windows\Setup\Scripts inside the image
         - bundles the installer of every app in config\apps.txt (winget download), so the
           new PC installs them offline
    4. Commits, re-compresses, and writes autounattend.xml (Rufus-style install) to the ISO root.
    5. Builds a bootable BIOS + UEFI ISO with oscdimg (Windows ADK).

    Run from an elevated PowerShell on Windows 10/11. Nothing on your own PC is changed
    except the work folder you choose.

.EXAMPLE
    .\Build-CustomISO.ps1 -SourceIso D:\ISOs\Win11_25H2_English_x64.iso -UserName Renmiri

.EXAMPLE
    .\Build-CustomISO.ps1 -SourceIso .\Win11.iso -Edition "Windows 11 Home" -OutputIso C:\Out\Win11-Home-Custom.iso
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SourceIso,
    [string] $Edition    = 'Windows 11 Pro',
    [string] $UserName   = 'Renmiri',
    [string] $WorkDir    = 'C:\Win11Build',
    [string] $OutputIso  = '',
    # Keep BitLocker's automatic device encryption from turning on (Rufus does this too).
    [bool]   $PreventDeviceEncryption = $true,
    # Boot straight into Setup without the "Press any key to boot from CD or DVD" prompt.
    [switch] $NoPrompt,
    # Runs DISM component cleanup on the image. Smaller ISO, but takes 15-40 minutes.
    [switch] $CleanupComponents,
    # Path to oscdimg.exe if it is not in the default Windows ADK location.
    [string] $OscdimgPath = '',
    # Don't bundle app installers; the PC downloads them with winget at first sign-in instead.
    [switch] $NoAppDownload,
    # Re-download app installers even if a cached copy exists in <WorkDir>\downloads.
    [switch] $RefreshDownloads
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Note($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

# ---------------------------------------------------------------- resilient .reg import
# reg.exe import stops reporting at the first protected key and leaves the rest of the file
# half-applied. Instead, every value is written one at a time with .NET. If a key is protected
# (owned by TrustedInstaller / SYSTEM), Administrators take ownership of it and the write is retried.
# Anything that still fails is listed at the end of the step.
if (-not ('TokenPrivilege' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TokenPrivilege {
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr process, int access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool LookupPrivilegeValue(string host, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TokPriv newState, int len, IntPtr prev, IntPtr retLen);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct TokPriv { public int Count; public long Luid; public int Attr; }
    public static bool Enable(string privilege) {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) return false;
        TokPriv tp; tp.Count = 1; tp.Attr = 2;
        if (!LookupPrivilegeValue(null, privilege, out tp.Luid)) return false;
        return AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
    }
}
'@
}
foreach ($priv in 'SeTakeOwnershipPrivilege', 'SeRestorePrivilege', 'SeBackupPrivilege') { [void][TokenPrivilege]::Enable($priv) }

$HKLM   = [Microsoft.Win32.Registry]::LocalMachine
$Admins = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')

# Make Administrators owner of a key (and optionally all its subkeys) with full control.
function Grant-KeyAccess([string]$sub, [switch]$Recurse) {
    try {
        $k = $HKLM.OpenSubKey($sub, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                              [Security.AccessControl.RegistryRights]::TakeOwnership)
        if (-not $k) { return }
        $acl = New-Object Security.AccessControl.RegistrySecurity
        $acl.SetOwner($Admins)
        $k.SetAccessControl($acl); $k.Close()
        $k = $HKLM.OpenSubKey($sub, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                              [Security.AccessControl.RegistryRights]::ChangePermissions -bor [Security.AccessControl.RegistryRights]::ReadKey)
        $acl = $k.GetAccessControl()
        $rule = New-Object Security.AccessControl.RegistryAccessRule($Admins, 'FullControl', 'ContainerInherit', 'None', 'Allow')
        $acl.SetAccessRule($rule)
        $k.SetAccessControl($acl)
        $names = if ($Recurse) { $k.GetSubKeyNames() } else { @() }
        $k.Close()
        foreach ($n in $names) { Grant-KeyAccess "$sub\$n" -Recurse }
    } catch { }
}

# Deepest part of $sub that already exists (where a new subkey would be created).
function Get-ExistingParent([string]$sub) {
    $p = $sub
    while ($p -and -not ($k = $HKLM.OpenSubKey($p))) { $p = Split-Path $p -Parent }
    if ($k) { $k.Close() }
    return $p
}

function Invoke-WithOwnership([string]$sub, [scriptblock]$action, [switch]$Tree) {
    try { & $action; return $true } catch { }
    $target = if ($Tree) { $sub } else { Get-ExistingParent $sub }
    if ($target) { Grant-KeyAccess $target -Recurse:$Tree }
    if (-not $Tree -and $target -ne $sub) { $e = $HKLM.OpenSubKey($sub); if ($e) { $e.Close(); Grant-KeyAccess $sub } }
    try { & $action; return $true } catch { return $false }
}

function Import-RegFile([string]$file) {
    $failed = @(); $ok = 0; $key = $null; $deleteKey = $false
    foreach ($raw in Get-Content $file) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith(';') -or $line -like 'Windows Registry Editor*') { continue }
        if ($line -match '^\[(-?)HKEY_LOCAL_MACHINE\\(.+)\]$') {
            $deleteKey = ($Matches[1] -eq '-'); $key = $Matches[2]
            if ($deleteKey) {
                $k = $key
                $done = Invoke-WithOwnership $k { $HKLM.DeleteSubKeyTree($k, $false) } -Tree
                if ($done) { $ok++ } else { $failed += "delete $k" }
            } else {
                $k = $key
                $done = Invoke-WithOwnership $k { $HKLM.CreateSubKey($k).Close() }
                if (-not $done) { $failed += "create $k" }
            }
            continue
        }
        if (-not $key -or $deleteKey) { continue }
        if ($line -notmatch '^(@|"(?:[^"\\]|\\.)*")=(.*)$') { $failed += "unparsed: $line"; continue }
        $name = if ($Matches[1] -eq '@') { '' } else { $Matches[1].Substring(1, $Matches[1].Length - 2) -replace '\\(.)', '$1' }
        $data = $Matches[2]
        $k = $key
        if ($data -eq '-') {
            $action = { $h = $HKLM.OpenSubKey($k, $true); if ($h) { $h.DeleteValue($name, $false); $h.Close() } }
        } elseif ($data -match '^dword:([0-9a-fA-F]{8})$') {
            $num = [Convert]::ToInt32($Matches[1], 16)
            $action = { $h = $HKLM.CreateSubKey($k); $h.SetValue($name, $num, [Microsoft.Win32.RegistryValueKind]::DWord); $h.Close() }
        } elseif ($data -match '^"(.*)"$') {
            $str = $Matches[1] -replace '\\(.)', '$1'
            $action = { $h = $HKLM.CreateSubKey($k); $h.SetValue($name, $str, [Microsoft.Win32.RegistryValueKind]::String); $h.Close() }
        } else { $failed += "unsupported value type: $line"; continue }
        if (Invoke-WithOwnership $k $action) { $ok++ } else { $failed += "$k\$name" }
    }
    return [pscustomobject]@{ Ok = $ok; Failed = $failed }
}

# ---------------------------------------------------------------- pre-checks
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated (Run as administrator) PowerShell window.'
}
$SourceIso = (Resolve-Path $SourceIso).Path

if ($UserName -notmatch '^[A-Za-z0-9._ -]{1,20}$' -or $UserName -match '^(Administrator|Guest|DefaultAccount|WDAGUtilityAccount)$') {
    throw "UserName '$UserName' is not valid. Use 1-20 letters, digits, space, dot, dash or underscore, and not a built-in account name."
}

if (-not $OscdimgPath) {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "$env:ProgramFiles\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        (Join-Path $Root 'oscdimg.exe')
    )
    $OscdimgPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $OscdimgPath -or -not (Test-Path $OscdimgPath)) {
    throw @'
oscdimg.exe was not found. Install the Windows ADK and tick only "Deployment Tools":
  winget install --id Microsoft.WindowsADK -e
or download it from https://learn.microsoft.com/windows-hardware/get-started/adk-install
You can also copy oscdimg.exe next to this script, or pass -OscdimgPath.
'@
}

$IsoDir   = Join-Path $WorkDir 'iso'
$MountDir = Join-Path $WorkDir 'mount'
$TempWim  = Join-Path $WorkDir 'install-edit.wim'
if (-not $OutputIso) { $OutputIso = Join-Path $WorkDir ("Win11-Custom-{0:yyyyMMdd}.iso" -f (Get-Date)) }

# Clean up a previous failed run.
Clear-WindowsCorruptMountPoint -ErrorAction SilentlyContinue | Out-Null
if (Test-Path $MountDir) {
    if (Get-WindowsImage -Mounted | Where-Object { $_.Path -eq $MountDir }) {
        Write-Step 'Discarding a leftover mounted image from a previous run'
        Dismount-WindowsImage -Path $MountDir -Discard | Out-Null
    }
}
foreach ($m in Get-WindowsImage -Mounted | Where-Object { $_.Path -eq (Join-Path $WorkDir 'bootmount') }) {
    Dismount-WindowsImage -Path $m.Path -Discard | Out-Null
}
foreach ($d in $IsoDir, $MountDir, (Join-Path $WorkDir 'bootmount')) { if (Test-Path $d) { Remove-Item $d -Recurse -Force } }
if (Test-Path $TempWim) { Remove-Item $TempWim -Force }
New-Item -ItemType Directory -Force -Path $IsoDir, $MountDir | Out-Null

# ---------------------------------------------------------------- 1. copy ISO
Write-Step "Copying ISO contents to $IsoDir"
$disk = Mount-DiskImage -ImagePath $SourceIso -PassThru
try {
    Start-Sleep -Seconds 2
    $drive = "$(($disk | Get-Volume).DriveLetter):"
    robocopy "$drive\." $IsoDir /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }
} finally {
    Dismount-DiskImage -ImagePath $SourceIso | Out-Null
}
Get-ChildItem $IsoDir -Recurse -File | ForEach-Object { $_.IsReadOnly = $false }

# ---------------------------------------------------------------- 2. pick edition
$srcImage = Join-Path $IsoDir 'sources\install.wim'
if (-not (Test-Path $srcImage)) { $srcImage = Join-Path $IsoDir 'sources\install.esd' }
if (-not (Test-Path $srcImage)) { throw 'No sources\install.wim or install.esd in the ISO. Is this a Windows 11 ISO?' }

$images = Get-WindowsImage -ImagePath $srcImage
Write-Step 'Editions in this ISO:'
$images | ForEach-Object { Write-Note ("[{0}] {1}" -f $_.ImageIndex, $_.ImageName) }
$pick = $images | Where-Object { $_.ImageName -eq $Edition } | Select-Object -First 1
if (-not $pick) { throw "Edition '$Edition' not found. Pass one of the names above with -Edition." }
Write-Note "Using [$($pick.ImageIndex)] $($pick.ImageName)"

Write-Step 'Exporting the chosen edition to a working WIM'
Export-WindowsImage -SourceImagePath $srcImage -SourceIndex $pick.ImageIndex `
    -DestinationImagePath $TempWim -CompressionType max -CheckIntegrity | Out-Null

# ---------------------------------------------------------------- 2b. download app installers
$DownloadDir = Join-Path $WorkDir 'downloads'
if (-not $NoAppDownload) {
    Write-Step 'Downloading app installers listed in config\apps.txt (winget download)'
    $wg = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $wg) { throw 'winget is needed to download the app installers. Install "App Installer" from the Microsoft Store, or rerun with -NoAppDownload.' }
    $ids = Get-Content (Join-Path $Root 'config\apps.txt') |
        ForEach-Object { ($_ -split '#')[0].Trim() } |
        Where-Object { $_ -and $_ -notmatch '^@' } |
        ForEach-Object { ($_ -split '\|')[0].Trim() }
    $failed = @()
    foreach ($id in $ids) {
        $dir = Join-Path $DownloadDir $id
        if (-not $RefreshDownloads -and (Get-ChildItem $dir -Filter '*.yaml' -ErrorAction SilentlyContinue)) {
            Write-Note "cached   $id"; continue
        }
        if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        & $wg.Source download --id $id --exact --download-directory $dir --skip-dependencies `
            --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
        $files = Get-ChildItem $dir -File -ErrorAction SilentlyContinue
        if (($files | Where-Object Extension -eq '.yaml') -and ($files | Where-Object Extension -ne '.yaml')) {
            $mb = [math]::Round((($files | Measure-Object Length -Sum).Sum) / 1MB, 1)
            Write-Note "bundled  $id ($mb MB)"
        } else {
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
            $failed += $id
            Write-Warning "could not download $id. It will be installed online at first sign-in instead."
        }
    }
    if ($failed) { Write-Note ("not bundled: " + ($failed -join ', ')) }
}

# Answer file with the account name filled in (used in the ISO root and inside the image).
$xml = Get-Content (Join-Path $Root 'autounattend.xml') -Raw
$xml = $xml.Replace('__USERNAME__', [Security.SecurityElement]::Escape($UserName))
$Utf8 = New-Object Text.UTF8Encoding($false)

# ---------------------------------------------------------------- 3. mount + customize
Write-Step 'Mounting the image (takes a few minutes)'
Mount-WindowsImage -ImagePath $TempWim -Index 1 -Path $MountDir | Out-Null
$committed = $false
try {
    # --- 3a. remove provisioned apps
    Write-Step 'Removing bloat apps (config\remove-apps.txt)'
    $patterns = Get-Content (Join-Path $Root 'config\remove-apps.txt') |
        ForEach-Object { ($_ -split '#')[0].Trim() } | Where-Object { $_ }
    # Never removed, even if a pattern matches: removing these breaks the Store, winget or Windows Security.
    $protected = @(
        'Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.DesktopAppInstaller',
        'Microsoft.SecHealthUI', 'Microsoft.VCLibs*', 'Microsoft.UI.Xaml*', 'Microsoft.NET.Native*',
        'Microsoft.WindowsAppRuntime*', 'Microsoft.WindowsTerminal', 'Microsoft.WindowsNotepad'
    )
    $provisioned = Get-AppxProvisionedPackage -Path $MountDir
    foreach ($pkg in $provisioned) {
        $name = $pkg.DisplayName
        if ($protected | Where-Object { $name -like $_ }) { continue }
        if ($patterns | Where-Object { $name -like $_ }) {
            try {
                Remove-AppxProvisionedPackage -Path $MountDir -PackageName $pkg.PackageName | Out-Null
                Write-Note "removed  $name"
            } catch { Write-Warning "could not remove $name : $($_.Exception.Message)" }
        }
    }

    # --- 3a2. drivers (every .inf under drivers\, recursively)
    $drvDir = Join-Path $Root 'drivers'
    if (Test-Path $drvDir) {
        $infs = @(Get-ChildItem $drvDir -Recurse -Filter '*.inf' -File)
        if ($infs.Count) {
            Write-Step "Adding $($infs.Count) driver .inf file(s) from drivers\"
            foreach ($sub in Get-ChildItem $drvDir -Directory) {
                $payload = Get-ChildItem $sub.FullName -Recurse -File | Where-Object { $_.Extension -ne '.txt' }
                if (-not $payload) { Write-Note "$($sub.Name): empty, skipped"; continue }
                if (-not (Get-ChildItem $sub.FullName -Recurse -Filter '*.inf' -File | Select-Object -First 1)) {
                    Write-Warning "drivers\$($sub.Name) has no .inf files. Extract the download first, or use offline-installers\ for .exe-only drivers."
                    continue
                }
                # One .inf at a time, so a single unsuitable file (e.g. the 32-bit copy that many
                # packages also ship) is skipped instead of failing the whole folder.
                $ok = 0; $skipped = 0
                foreach ($inf in Get-ChildItem $sub.FullName -Recurse -Filter '*.inf' -File) {
                    try {
                        Add-WindowsDriver -Path $MountDir -Driver $inf.FullName -ErrorAction Stop | Out-Null
                        $ok++
                    } catch { $skipped++ }
                }
                if ($ok) { Write-Note ("{0}: {1} driver(s) added, {2} skipped (wrong architecture or not a driver)" -f $sub.Name, $ok, $skipped) }
                else { Write-Warning "drivers\$($sub.Name): none of its $skipped .inf file(s) could be added." }
            }
        }
    }

    # --- 3b. optional features
    Write-Step 'Disabling Recall (if this build has it)'
    $recall = Get-WindowsOptionalFeature -Path $MountDir | Where-Object { $_.FeatureName -eq 'Recall' }
    if ($recall -and $recall.State -ne 'Disabled') {
        Disable-WindowsOptionalFeature -Path $MountDir -FeatureName Recall -NoRestart | Out-Null
        Write-Note 'Recall disabled'
    } else { Write-Note 'Recall not present' }

    # --- 3c. offline registry tweaks
    Write-Step 'Applying registry tweaks to the offline image'
    $hives = [ordered]@{
        'WIM_SOFTWARE' = Join-Path $MountDir 'Windows\System32\config\SOFTWARE'
        'WIM_SYSTEM'   = Join-Path $MountDir 'Windows\System32\config\SYSTEM'
        'WIM_DEFAULT'  = Join-Path $MountDir 'Users\Default\NTUSER.DAT'
    }
    foreach ($h in $hives.GetEnumerator()) {
        reg load "HKLM\$($h.Key)" $h.Value | Out-Null
        if ($LASTEXITCODE) { throw "reg load failed for $($h.Value)" }
    }
    try {
        $allFailed = @()
        foreach ($f in Get-ChildItem (Join-Path $Root 'tweaks') -Filter '*.reg' | Sort-Object Name) {
            $r = Import-RegFile $f.FullName
            Write-Note ("{0}: {1} setting(s) applied, {2} failed" -f $f.Name, $r.Ok, @($r.Failed).Count)
            $allFailed += $r.Failed | ForEach-Object { "$($f.Name): $_" }
        }
        if ($allFailed) {
            Write-Warning 'These registry settings could not be written (the rest were applied):'
            $allFailed | ForEach-Object { Write-Warning "  $_" }
        }
        if ($PreventDeviceEncryption) {
            reg add 'HKLM\WIM_SYSTEM\ControlSet001\Control\BitLocker' /v PreventDeviceEncryption /t REG_DWORD /d 1 /f | Out-Null
            Write-Note 'automatic BitLocker device encryption: off'
        }
    } finally {
        $HKLM.Flush()
        [GC]::Collect(); [GC]::WaitForPendingFinalizers(); Start-Sleep -Seconds 2
        foreach ($h in $hives.Keys) {
            for ($try = 1; $try -le 5; $try++) {
                reg unload "HKLM\$h" | Out-Null
                if (-not $LASTEXITCODE) { break }
                Start-Sleep -Seconds 3
            }
            if ($LASTEXITCODE) { throw "Could not unload HKLM\$h. Close regedit and try again." }
        }
    }

    # --- 3d. remove the OneDrive installer so it can never run for new users
    $odSetup = Join-Path $MountDir 'Windows\System32\OneDriveSetup.exe'
    if (Test-Path $odSetup) {
        takeown /f $odSetup /a | Out-Null
        icacls $odSetup /grant '*S-1-5-32-544:F' | Out-Null
        Remove-Item $odSetup -Force
        Write-Note 'OneDriveSetup.exe removed from the image'
    }

    # --- 3d2. answer file inside the image
    # Windows also looks in C:\Windows\System32\Sysprep for unattend.xml during the specialize and
    # oobeSystem passes, so the local account, skipped OOBE pages and first-logon script still
    # happen even if Setup didn't pick up the ISO's autounattend.xml (e.g. booted via Ventoy).
    [IO.File]::WriteAllText((Join-Path $MountDir 'Windows\System32\Sysprep\unattend.xml'), $xml, $Utf8)
    Write-Note 'answer file also placed in Windows\System32\Sysprep\unattend.xml'

    # --- 3e. first-logon scripts and config
    Write-Step 'Copying first-logon scripts into the image'
    $dest = Join-Path $MountDir 'Windows\Setup\Scripts'
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item (Join-Path $Root 'scripts\*') $dest -Recurse -Force
    Copy-Item (Join-Path $Root 'config\apps.txt') $dest -Force
    Copy-Item (Join-Path $Root 'config\remove-apps.txt') $dest -Force
    $offline = Join-Path $Root 'offline-installers'
    if (Test-Path $offline) { Copy-Item $offline (Join-Path $dest 'offline-installers') -Recurse -Force }
    if (-not $NoAppDownload -and (Test-Path $DownloadDir)) {
        New-Item -ItemType Directory -Force -Path (Join-Path $dest 'offline-installers\winget') | Out-Null
        Copy-Item (Join-Path $DownloadDir '*') (Join-Path $dest 'offline-installers\winget') -Recurse -Force
    }

    if ($CleanupComponents) {
        Write-Step 'Cleaning up the component store (slow)'
        dism /Image:$MountDir /Cleanup-Image /StartComponentCleanup /ResetBase
    }

    Write-Step 'Saving and unmounting the image'
    Dismount-WindowsImage -Path $MountDir -Save | Out-Null
    $committed = $true
} finally {
    if (-not $committed) {
        Write-Warning 'Something failed. Discarding the mounted image.'
        Dismount-WindowsImage -Path $MountDir -Discard -ErrorAction SilentlyContinue | Out-Null
    }
}

# ---------------------------------------------------------------- 4. put image + unattend in place
Write-Step 'Re-compressing the image into the ISO folder'
Remove-Item (Join-Path $IsoDir 'sources\install.wim'), (Join-Path $IsoDir 'sources\install.esd') -Force -ErrorAction SilentlyContinue
Export-WindowsImage -SourceImagePath $TempWim -SourceIndex 1 `
    -DestinationImagePath (Join-Path $IsoDir 'sources\install.wim') -CompressionType max -CheckIntegrity | Out-Null
Remove-Item $TempWim -Force

Write-Step 'Writing autounattend.xml'
[IO.File]::WriteAllText((Join-Path $IsoDir 'autounattend.xml'), $xml, $Utf8)

# ---------------------------------------------------------------- 4b. hardware-check bypass inside boot.wim
# Setup's TPM / Secure Boot / RAM / CPU check is skipped even if Setup never reads the
# autounattend.xml in the ISO root (e.g. some USB boot tools such as Ventoy).
Write-Step 'Adding the hardware-check bypass to the installer (boot.wim)'
$BootWim   = Join-Path $IsoDir 'sources\boot.wim'
$BootMount = Join-Path $WorkDir 'bootmount'
New-Item -ItemType Directory -Force -Path $BootMount | Out-Null
Set-ItemProperty $BootWim -Name IsReadOnly -Value $false
Mount-WindowsImage -ImagePath $BootWim -Index 2 -Path $BootMount | Out-Null
$bootSaved = $false
try {
    reg load 'HKLM\WIM_BOOTSYS' (Join-Path $BootMount 'Windows\System32\config\SYSTEM') | Out-Null
    if ($LASTEXITCODE) { throw 'reg load failed for boot.wim SYSTEM hive' }
    try {
        foreach ($v in 'BypassTPMCheck', 'BypassSecureBootCheck', 'BypassRAMCheck', 'BypassStorageCheck', 'BypassCPUCheck') {
            reg add 'HKLM\WIM_BOOTSYS\Setup\LabConfig' /v $v /t REG_DWORD /d 1 /f | Out-Null
        }
    } finally {
        [GC]::Collect(); [GC]::WaitForPendingFinalizers(); Start-Sleep -Seconds 2
        reg unload 'HKLM\WIM_BOOTSYS' | Out-Null
    }
    Dismount-WindowsImage -Path $BootMount -Save | Out-Null
    $bootSaved = $true
} finally {
    if (-not $bootSaved) { Dismount-WindowsImage -Path $BootMount -Discard -ErrorAction SilentlyContinue | Out-Null }
}
Remove-Item $BootMount -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- 5. build ISO
Write-Step "Building $OutputIso"
$etfs = Join-Path $IsoDir 'boot\etfsboot.com'
$efi  = Join-Path $IsoDir ('efi\microsoft\boot\' + $(if ($NoPrompt) { 'efisys_noprompt.bin' } else { 'efisys.bin' }))
if (-not (Test-Path $efi)) { $efi = Join-Path $IsoDir 'efi\microsoft\boot\efisys.bin' }
if (-not (Test-Path $efi)) { $efi = Join-Path (Split-Path $OscdimgPath) $(if ($NoPrompt) { 'efisys_noprompt.bin' } else { 'efisys.bin' }) }
if ($IsoDir -match ' ' -or $OutputIso -match ' ') { Write-Warning 'oscdimg can fail on paths with spaces. Use -WorkDir / -OutputIso without spaces if it does.' }
$label = 'WIN11_CUSTOM'
& $OscdimgPath -m -o -u2 -udfver102 "-l$label" "-bootdata:2#p0,e,b$etfs#pEF,e,b$efi" $IsoDir $OutputIso
if ($LASTEXITCODE) { throw "oscdimg failed with exit code $LASTEXITCODE" }

$size = [math]::Round((Get-Item $OutputIso).Length / 1GB, 2)
Write-Host "`nDone. $OutputIso ($size GB)" -ForegroundColor Green
Write-Host 'Copy it onto your Ventoy USB stick (or write it with Rufus and untick its Windows'
Write-Host 'customization dialog). Everything is already inside. Test it in a VM first if you can.'
