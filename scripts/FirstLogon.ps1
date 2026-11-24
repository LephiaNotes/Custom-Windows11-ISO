<#
    Runs once, at the first sign-in after Windows Setup (from autounattend.xml FirstLogonCommands).
    Lives in C:\Windows\Setup\Scripts on the installed PC. Log: C:\Windows\Setup\Scripts\FirstLogon.log

    1. Removes OneDrive if it is still present.
    2. Removes any listed bloat app that came back for this user (e.g. via Store updates).
    3. Installs every app in apps.txt from the installers bundled into the ISO
       (offline-installers\winget\<Id>). Anything not bundled is installed online with winget.
    4. Runs any installers in offline-installers\installers.csv (empty by default).
#>
$ErrorActionPreference = 'Continue'
$Here = $PSScriptRoot
Start-Transcript -Path (Join-Path $Here 'FirstLogon.log') -Append | Out-Null
$Host.UI.RawUI.WindowTitle = 'Finishing setup - installing your apps. Please wait...'

function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }

# ------------------------------------------------------------------ OneDrive
Step 'Removing OneDrive (if present)'
Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force
foreach ($exe in "$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") {
    if (Test-Path $exe) { Start-Process $exe '/uninstall' -Wait }
}
Get-AppxPackage -Name 'Microsoft.OneDriveSync' -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction SilentlyContinue
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name OneDriveSetup, OneDrive -ErrorAction SilentlyContinue
# Hide the OneDrive entry in the Explorer sidebar
New-Item 'HKCU:\Software\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}' -Force | Out-Null
Set-ItemProperty 'HKCU:\Software\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}' -Name 'System.IsPinnedToNameSpaceTree' -Value 0 -Type DWord

# ------------------------------------------------------------------ Bloat that came back
Step 'Removing bloat apps that came back'
$protected = @('Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.DesktopAppInstaller',
               'Microsoft.SecHealthUI', 'Microsoft.VCLibs*', 'Microsoft.UI.Xaml*', 'Microsoft.NET.Native*',
               'Microsoft.WindowsAppRuntime*', 'Microsoft.WindowsTerminal', 'Microsoft.WindowsNotepad')
$listFile = Join-Path $Here 'remove-apps.txt'
if (Test-Path $listFile) {
    $patterns = Get-Content $listFile | ForEach-Object { ($_ -split '#')[0].Trim() } | Where-Object { $_ }
    foreach ($p in $patterns) {
        Get-AppxPackage -Name $p -ErrorAction SilentlyContinue | Where-Object {
            $n = $_.Name; -not ($protected | Where-Object { $n -like $_ })
        } | ForEach-Object {
            Write-Host "    removing $($_.Name)"
            Remove-AppxPackage -Package $_.PackageFullName -ErrorAction SilentlyContinue
        }
    }
}

# ------------------------------------------------------------------ Widgets policy
# Windows won't let this key be written into the offline image, so set it here (we run as admin).
Step 'Turning off Widgets'
try {
    New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Force -ErrorAction Stop | Out-Null
    Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name AllowNewsAndInterests -Value 0 -Type DWord -ErrorAction Stop
    Write-Host '    Widgets policy set'
} catch {
    Write-Warning "Could not set the Widgets policy ($($_.Exception.Message)). Turn Widgets off in Settings > Personalization > Taskbar if it shows."
}

# ------------------------------------------------------------------ App list
# "{Gaming Drive}\Some\Folder" -> "E:\Some\Folder":
#   1. the drive whose volume label is "Gaming Drive", if there is one;
#   2. otherwise the second internal drive: the largest fixed NTFS drive that isn't the Windows
#      drive (USB sticks/SD cards are skipped). It gets labelled "Gaming Drive" so later runs find it.
#   3. no such drive: $null, and the app goes to its normal folder on C:.
# Plain paths like "D:\Apps\VLC" are used as-is.
$script:LabelCache = @{}
function Get-LabelledDrive([string]$label) {
    if ($script:LabelCache.ContainsKey($label)) { return $script:LabelCache[$label] }
    $result = $null
    $vol = Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.FileSystemLabel -eq $label -and $_.DriveLetter } | Select-Object -First 1
    if ($vol) {
        $result = "$($vol.DriveLetter):"
        Write-Host "    drive labelled '$label' found: $result"
    } else {
        $sys = $env:SystemDrive.TrimEnd(':')
        $cands = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object {
            $_.DriveLetter -and "$($_.DriveLetter)" -ne $sys -and $_.DriveType -eq 'Fixed' -and
            ($_.FileSystemType -eq 'NTFS' -or $_.FileSystem -eq 'NTFS') -and $_.Size -gt 16GB
        } | Where-Object {
            $disk = Get-Partition -DriveLetter $_.DriveLetter -ErrorAction SilentlyContinue | Get-Disk -ErrorAction SilentlyContinue
            $disk -and "$($disk.BusType)" -notin @('USB', 'SD', 'MMC', 'File Backed Virtual')
        } | Sort-Object Size -Descending)
        if ($cands.Count -ge 1) {
            $pick = $cands[0]
            $result = "$($pick.DriveLetter):"
            Write-Host ("    no drive labelled '{0}', using second drive {1} ({2:N0} GB) and labelling it '{0}'" -f $label, $result, ($pick.Size / 1GB))
            if ($cands.Count -gt 1) {
                Write-Host ("    other drives not used: " + (($cands | Select-Object -Skip 1 | ForEach-Object { "$($_.DriveLetter): ($([math]::Round($_.Size / 1GB)) GB)" }) -join ', '))
            }
            try { Set-Volume -DriveLetter $pick.DriveLetter -NewFileSystemLabel $label -ErrorAction Stop }
            catch { Write-Warning "could not label $result as '$label': $($_.Exception.Message)" }
        } else {
            Write-Warning "no drive labelled '$label' and no second internal drive found"
        }
    }
    $script:LabelCache[$label] = $result
    return $result
}

function Resolve-AppPath([string]$path) {
    if ($path -match '^\{(.+?)\}(.*)$') {
        $drive = Get-LabelledDrive $Matches[1]
        if (-not $drive) { return $null }
        $path = $drive + $Matches[2]
    }
    $qualifier = Split-Path $path -Qualifier -ErrorAction SilentlyContinue
    if (-not $qualifier -or -not (Test-Path "$qualifier\")) { return $null }
    return $path
}

$lines = Get-Content (Join-Path $Here 'apps.txt') -ErrorAction SilentlyContinue |
    ForEach-Object { ($_ -split '#')[0].Trim() } | Where-Object { $_ }
$defaultRoot = $null
$apps = @()
foreach ($line in $lines) {
    if ($line -match '^@default\s+(.+)$') { $defaultRoot = $Matches[1].Trim(); continue }
    $parts = $line -split '\|'
    $id = $parts[0].Trim()
    $ask = ($parts.Count -gt 2 -and $parts[2].Trim() -eq 'ask')
    $loc = if ($parts.Count -gt 1 -and $parts[1].Trim()) { $parts[1].Trim() }
           elseif ($defaultRoot) { Join-Path $defaultRoot ($id -split '\.')[-1] }
           else { $null }
    $target = $null
    if ($loc) {
        $target = Resolve-AppPath $loc
        if ($target) { New-Item -ItemType Directory -Force -Path $target | Out-Null }
        else { Write-Warning "drive for '$loc' not found, $id goes to its default folder" }
    }
    $apps += [pscustomobject]@{ Id = $id; Target = $target; Ask = $ask }
}

function Show-AskHint($app) {
    Write-Host ''
    Write-Host "    >>> The $($app.Id) installer opens in its own window. Install it to:" -ForegroundColor Yellow
    Write-Host "    >>>   $($app.Target)" -ForegroundColor Yellow
    Write-Host "    >>> (League: click the folder / 'Advanced options' link before Install, paste with Ctrl+V.)" -ForegroundColor Yellow
    Set-Clipboard -Value $app.Target -ErrorAction SilentlyContinue
    Write-Host '    >>> That path is already copied to the clipboard. This window waits until you finish.' -ForegroundColor Yellow
}

# ------------------------------------------------------------------ Bundled installers (offline)
# The build put each app's installer + its winget manifest in offline-installers\winget\<Id>\.
# The silent / install-folder switches come from that manifest, or the usual ones for its installer type.
function Get-YamlValue([string]$text, [string]$key) {
    $m = [regex]::Match($text, "(?m)^\s*-?\s*$([regex]::Escape($key)):\s*(.+?)\s*$")
    if (-not $m.Success) { return $null }
    $v = $m.Groups[1].Value
    if ($v -match "^'(.*)'$" -or $v -match '^"(.*)"$') { $v = $Matches[1] }
    return $v
}

function Install-Bundled($app) {
    $dir = Join-Path $Here ("offline-installers\winget\" + $app.Id)
    $yaml = Get-ChildItem $dir -Filter '*.yaml' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    $file = Get-ChildItem $dir -File -ErrorAction SilentlyContinue | Where-Object Extension -ne '.yaml' | Select-Object -First 1
    if (-not $yaml -or -not $file) { return $null }

    $text = Get-Content $yaml.FullName -Raw
    $type = "$(Get-YamlValue $text 'InstallerType')".ToLower()
    $path = $file.FullName
    if ($type -eq 'zip') {
        $out = Join-Path $env:TEMP ("unzip-" + $app.Id)
        Expand-Archive $path $out -Force
        $type = "$(Get-YamlValue $text 'NestedInstallerType')".ToLower()
        $path = Join-Path $out (Get-YamlValue $text 'RelativeFilePath')
    }

    $silent = Get-YamlValue $text 'Silent'
    if (-not $silent) { $silent = Get-YamlValue $text 'SilentWithProgress' }
    $custom = Get-YamlValue $text 'Custom'
    $locSw  = Get-YamlValue $text 'InstallLocation'
    switch -Regex ($type) {
        '^nullsoft$'  { if (-not $silent) { $silent = '/S' };  if (-not $locSw) { $locSw = '/D=<INSTALLPATH>' } }
        '^inno$'      { if (-not $silent) { $silent = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-' }
                        if (-not $locSw) { $locSw = '/DIR="<INSTALLPATH>"' } }
        '^(msi|wix)$' { if (-not $silent) { $silent = '/quiet /norestart' }
                        if (-not $locSw) { $locSw = 'INSTALLDIR="<INSTALLPATH>"' } }
        '^burn$'      { if (-not $silent) { $silent = '/quiet /norestart' } }
    }

    if ($type -match '^(msix|appx)$') {
        try { Add-AppxPackage -Path $path -ErrorAction Stop; return 0 } catch { Write-Warning $_.Exception.Message; return 1 }
    }

    if ($app.Ask) {
        Show-AskHint $app
        $argLine = ''                                  # interactive: the installer's own window
    } else {
        $argLine = (@($silent, $custom) | Where-Object { $_ }) -join ' '
        if ($app.Target -and $locSw) { $argLine += ' ' + $locSw.Replace('<INSTALLPATH>', $app.Target) }
        elseif ($app.Target) { Write-Host "    (this installer has no folder switch, using its default folder)" }
    }

    if ($type -match '^(msi|wix)$') {
        $p = Start-Process msiexec.exe "/i `"$path`" $argLine" -PassThru; $p.WaitForExit()
    } elseif ($argLine.Trim()) {
        $p = Start-Process $path $argLine.Trim() -PassThru; $p.WaitForExit()
    } else {
        if (-not $app.Ask -and $type -notmatch '^(nullsoft|inno|msi|wix|burn)$' -and -not $silent) {
            Write-Host "    >>> No silent switch known for $($app.Id): its setup window opens, click through it." -ForegroundColor Yellow
        }
        $p = Start-Process $path -PassThru; $p.WaitForExit()
    }
    return $p.ExitCode
}

$results = @()
$missing = @()
if ($apps) { Step 'Installing bundled apps (no internet needed)' }
$i = 0
foreach ($app in $apps) {
    $i++
    $where = if ($app.Target) { $app.Target } else { 'default folder' }
    Write-Host ("    [{0}/{1}] {2} -> {3}" -f $i, $apps.Count, $app.Id, $where)
    $code = Install-Bundled $app
    if ($null -eq $code) { Write-Host '        not bundled, will try online'; $missing += $app; continue }
    $ok = ($code -in 0, 1641, 3010)
    $results += [pscustomobject]@{ App = $app.Id; Where = $where; Result = $(if ($ok) { 'OK (offline)' } else { "FAILED ($code)" }) }
}

# ------------------------------------------------------------------ Online fallback (winget)
function Get-Winget {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $p = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path $p) { return $p }
    return $null
}

if ($missing) {
    Step 'Waiting for an internet connection for the apps that were not bundled (up to 10 minutes)'
    $deadline = (Get-Date).AddMinutes(10)
    $online = $false
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-WebRequest 'https://cdn.winget.microsoft.com/cache/source.msix' -Method Head -UseBasicParsing -TimeoutSec 10 | Out-Null
            $online = $true; break
        } catch { Start-Sleep -Seconds 10 }
    }

    $winget = $null
    if ($online) {
        try { Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop } catch {}
        $deadline = (Get-Date).AddMinutes(5)
        while (-not ($winget = Get-Winget) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 10 }
    }

    if ($winget) {
        & $winget source update --disable-interactivity | Out-Null
        foreach ($app in $missing) {
            $where = if ($app.Target) { $app.Target } else { 'default folder' }
            $wgArgs = @('install', '--id', $app.Id, '--exact', '--accept-package-agreements',
                        '--accept-source-agreements', '--disable-interactivity')
            if ($app.Ask -and $app.Target) { Show-AskHint $app; $wgArgs += '--interactive' }
            else {
                $wgArgs += '--silent'
                if ($app.Target) { $wgArgs += @('--location', $app.Target) }
            }
            Write-Host "    $($app.Id) (online)"
            & $winget @wgArgs
            $code = $LASTEXITCODE
            # 0 = ok; 0x8A15002B / 0x8A150061 = already installed / nothing to upgrade
            $ok = ($code -in 0, -1978335189, -1978335135)
            $results += [pscustomobject]@{ App = $app.Id; Where = $where; Result = $(if ($ok) { 'OK (online)' } else { "FAILED ($code)" }) }
        }
    } else {
        foreach ($app in $missing) { $results += [pscustomobject]@{ App = $app.Id; Where = '-'; Result = 'SKIPPED (no internet)' } }
        Write-Warning 'Some apps were not bundled and there is no internet. Run this script again later:'
        Write-Warning "  powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    }
}

# ------------------------------------------------------------------ Offline installers
$csv = Join-Path $Here 'offline-installers\installers.csv'
if (Test-Path $csv) {
    Step 'Running offline installers'
    foreach ($row in Import-Csv $csv) {
        # File may contain wildcards, e.g. Ableton\Ableton Live 12*Installer.exe
        $file = Get-Item (Join-Path $Here ("offline-installers\" + $row.File)) -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
        if (-not $file) { Write-Host "    (skipped, not found: $($row.File))"; continue }
        if (-not $row.Arguments) {
            Write-Host "    >>> $($row.File) opens its own setup window. Click through it; this script waits." -ForegroundColor Yellow
        }
        Write-Host "    $($row.File) $($row.Arguments)"
        if ($file -like '*.msi') {
            $p = Start-Process msiexec.exe "/i `"$file`" /qn /norestart $($row.Arguments)" -PassThru; $p.WaitForExit()
        } elseif ($row.Arguments) {
            $p = Start-Process $file $row.Arguments -PassThru; $p.WaitForExit()
        } else {
            $p = Start-Process $file -PassThru; $p.WaitForExit()
        }
        $results += [pscustomobject]@{ App = $row.File; Where = "offline"; Result = $(if ($p.ExitCode -in 0, 3010) { 'OK' } else { "FAILED ($($p.ExitCode))" }) }
    }
}

# ------------------------------------------------------------------ Summary
Step 'Summary'
if ($results) { $results | Format-Table -AutoSize | Out-String | Write-Host }
Write-Host 'Done. Full log: C:\Windows\Setup\Scripts\FirstLogon.log' -ForegroundColor Green
Write-Host 'You will be asked to set a password the next time you sign in.'
Stop-Transcript | Out-Null
Start-Sleep -Seconds 15
