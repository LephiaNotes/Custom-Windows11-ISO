<#
.SYNOPSIS
    Undoes the registry and service tweaks from tweaks\*.reg on an INSTALLED PC.
    Run from an elevated PowerShell, then restart.

    It does not reinstall removed apps; get those back from the Microsoft Store
    (e.g. search "Xbox", "Phone Link", "Copilot") or with winget.
    To get OneDrive back:  winget install Microsoft.OneDrive

.PARAMETER Only
    Revert just one area: Telemetry, Copilot, OneDrive, Ads, Services, DeliveryOptimization, GameBar, Drivers.
    Default: everything.
#>
param(
    [ValidateSet('All', 'Telemetry', 'Copilot', 'OneDrive', 'Ads', 'Services', 'DeliveryOptimization', 'GameBar', 'Drivers')]
    [string] $Only = 'All'
)
$ErrorActionPreference = 'Continue'

function Remove-Val($path, [string[]]$names) {
    foreach ($n in $names) { Remove-ItemProperty -Path $path -Name $n -ErrorAction SilentlyContinue }
}
function Want($area) { $Only -eq 'All' -or $Only -eq $area }

$P = 'HKLM:\SOFTWARE\Policies\Microsoft'
$U = 'HKCU:\Software'

if (Want 'Telemetry') {
    Remove-Val "$P\Windows\DataCollection" AllowTelemetry, AllowDeviceNameInTelemetry, DoNotShowFeedbackNotifications, LimitDiagnosticLogCollection, LimitDumpCollection
    Remove-Val 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' AllowTelemetry
    Remove-Val "$P\SQMClient\Windows" CEIPEnable
    Remove-Val "$P\Windows\AppCompat" AITEnable
    Remove-Val "$P\Windows\Windows Error Reporting" Disabled
    Remove-Val "$P\Windows\AdvertisingInfo" DisabledByGroupPolicy
    Remove-Val "$P\Windows\System" EnableActivityFeed, PublishUserActivities, UploadUserActivities
    Remove-Val "$P\Windows\OOBE" DisablePrivacyExperience
    Remove-Val "$U\Microsoft\Windows\CurrentVersion\AdvertisingInfo" Enabled
    Remove-Val "$U\Microsoft\Windows\CurrentVersion\Privacy" TailoredExperiencesWithDiagnosticDataEnabled
    Remove-Val "$U\Microsoft\Siuf\Rules" NumberOfSIUFInPeriod
    Remove-Val "$U\Microsoft\InputPersonalization" RestrictImplicitInkCollection, RestrictImplicitTextCollection
    Remove-Val "$U\Microsoft\InputPersonalization\TrainedDataStore" HarvestContacts
    Write-Host 'Telemetry policies reverted'
}

if (Want 'Copilot') {
    Remove-Val "$P\Windows\WindowsCopilot" TurnOffWindowsCopilot
    Remove-Val "$P\Windows\WindowsAI" DisableAIDataAnalysis, AllowRecallEnablement, DisableClickToDo
    Remove-Val "$P\Edge" HubsSidebarEnabled
    Remove-Val "$U\Policies\Microsoft\Windows\WindowsCopilot" TurnOffWindowsCopilot
    Remove-Val "$U\Policies\Microsoft\Windows\WindowsAI" DisableAIDataAnalysis
    Remove-Val "$U\Microsoft\Windows\CurrentVersion\Explorer\Advanced" ShowCopilotButton
    Write-Host 'Copilot/Recall policies reverted (reinstall the Copilot app from the Store if wanted)'
}

if (Want 'OneDrive') {
    Remove-Val "$P\Windows\OneDrive" DisableFileSyncNGSC
    Remove-Item "$U\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}" -Recurse -ErrorAction SilentlyContinue
    Write-Host 'OneDrive block removed. Install it with: winget install Microsoft.OneDrive'
}

if (Want 'Ads') {
    Remove-Val "$P\Windows\CloudContent" DisableWindowsConsumerFeatures, DisableConsumerAccountStateContent, DisableCloudOptimizedContent
    Remove-Val "$P\Dsh" AllowNewsAndInterests
    Remove-Val "$P\Windows\Windows Chat" ChatIcon
    Remove-Val 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Communications' ConfigureChatAutoInstall
    Remove-Val "$P\Windows\Windows Search" AllowCortana, DisableWebSearch, ConnectedSearchUseWeb
    Remove-Val "$U\Policies\Microsoft\Windows\Explorer" DisableSearchBoxSuggestions
    Remove-Val "$U\Microsoft\Windows\CurrentVersion\Search" BingSearchEnabled
    Remove-Val "$U\Microsoft\Windows\CurrentVersion\Explorer\Advanced" TaskbarDa, TaskbarMn, Start_IrisRecommendations, Start_AccountNotifications, ShowSyncProviderNotifications
    Remove-Val "$U\Microsoft\Windows\CurrentVersion\UserProfileEngagement" ScoobeSystemSettingEnabled
    $cdm = "$U\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
    if (Test-Path $cdm) {
        (Get-Item $cdm).Property | Where-Object { $_ -like '*Enabled' -or $_ -eq 'ContentDeliveryAllowed' } |
            ForEach-Object { Set-ItemProperty $cdm -Name $_ -Value 1 -Type DWord }
    }
    Write-Host 'Ads/suggestions settings reverted'
}

if (Want 'GameBar') {
    Remove-Val "$P\Windows\GameDVR" AllowGameDVR
    Remove-Item 'HKLM:\SOFTWARE\Classes\ms-gamebar', 'HKLM:\SOFTWARE\Classes\ms-gamingoverlay' -Recurse -ErrorAction SilentlyContinue
    Remove-Val 'HKCU:\System\GameConfigStore' GameDVR_Enabled
    Remove-Val "$U\Microsoft\Windows\CurrentVersion\GameDVR" AppCaptureEnabled
    Remove-Val "$U\Microsoft\GameBar" UseNexusForGameBarEnabled, ShowStartupPanel
    Write-Host 'Game Bar settings reverted (reinstall Xbox Game Bar from the Store)'
}

if (Want 'Drivers') {
    Remove-Val "$P\Windows\WindowsUpdate" ExcludeWUDriversInQualityUpdate
    Remove-Val "$P\Windows\Device Metadata" PreventDeviceMetadataFromNetwork
    Remove-Val 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata' PreventDeviceMetadataFromNetwork
    Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' -Name SearchOrderConfig -Value 1 -Type DWord
    Write-Host 'Windows Update can install drivers again'
}

if (Want 'DeliveryOptimization') {
    Remove-Val "$P\Windows\DeliveryOptimization" DODownloadMode
    Write-Host 'Delivery Optimization reverted'
}

if (Want 'Services') {
    # Windows defaults: DiagTrack Auto, dmwappushservice Manual, MapsBroker Auto (delayed), RetailDemo Manual
    $defaults = @{ DiagTrack = 'Automatic'; dmwappushservice = 'Manual'; MapsBroker = 'Automatic'; RetailDemo = 'Manual' }
    foreach ($s in $defaults.Keys) {
        if (Get-Service $s -ErrorAction SilentlyContinue) {
            Set-Service $s -StartupType $defaults[$s]
            Write-Host "service $s -> $($defaults[$s])"
        }
    }
    Start-Service DiagTrack -ErrorAction SilentlyContinue
}

Write-Host "`nDone. Restart the PC to apply everything." -ForegroundColor Green
