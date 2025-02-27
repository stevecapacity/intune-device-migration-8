<# REBOOT.PS1
Synopsis
Reboot.ps1 automatically changes the userSid and user profile ownership to the new user and reboots the machine.
DESCRIPTION
This script is used to change ownership of the original user profile to the destination user and then reboot the machine.  It is executed by the 'reboot' scheduled task.
USE
.\reboot.ps1
.OWNER
Steve Weiner
.CONTRIBUTORS
Logan Lautt

#>
$ErrorActionPreference = "SilentlyContinue"

# add message box function to script
Add-Type -AssemblyName PresentationFramework
function Show-MessageBox
{
    Param(
        [string]$Message,
        [string]$Title,
        [System.Windows.MessageBoxButton]$Button = [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]$Icon = [System.Windows.MessageBoxImage]::Information
    )
    [System.Windows.MessageBox]::Show($Message, $Title, $Button, $Icon)
}

# log function
function log()
{
    [Cmdletbinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string]$message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss tt"
    Write-Output "$timestamp - $message"
}


# Import config settings from JSON file
$config = Get-Content "C:\ProgramData\IntuneMigration\config.json" | ConvertFrom-Json

# Start Transcript
Start-Transcript -Path "$($config.logPath)\reboot.log" -Verbose
log "Starting Reboot.ps1..."

# Initialize script
$localPath = $config.localPath
if(!(Test-Path $localPath))
{
    log "$($localPath) does not exist.  Creating..."
    mkdir $localPath
}
else
{
    log "$($localPath) already exists."
}

# Check context
$context = whoami
log "Running as $($context)"

# disable reboot task
log "Disabling reboot task..."
Disable-ScheduledTask -TaskName "Reboot"
log "Reboot task disabled"

# disable auto logon
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "AutoAdminLogon" -Value 0 -Verbose
log "Auto logon enabled."

# set new wallpaper
$wallpaper = (Get-ChildItem -Path $config.localPath -Filter "*.jpg" -Recurse).FullName
if($wallpaper)
{
    log "Setting wallpaper..."
    Copy-Item -Path $wallpaper -Destination "C:\Windows\Web\Wallpaper" -Force
    $imgPath = "C:\Windows\Web\Wallpaper\$($wallpaper | Split-Path -Leaf)"
    [string]$desktopScreenPath = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP"

    log "Setting Lock screen wallpaper..."
    reg.exe add $desktopScreenPath /v "DesktopImagePath" /t REG_SZ /d $imgPath /f | Out-Host
    reg.exe add $desktopScreenPath /v "DesktopImageStatus" /t REG_DWORD /d 1 /f | Out-Host
}

# Retrieve variables from registry
log "Retrieving variables from registry..."
$regKey = "Registry::$($config.regPath)"
$values = Get-ItemProperty -Path $regKey
$values.PSObject.Properties | ForEach-Object {
    $name = $_.Name
    $value = $_.Value
    if(![string]::IsNullOrEmpty($value))
    {
        log "Retrieved $($name): $value"
        New-Variable -Name $name -Value $value -Force
    }
    else
    {
        log "Error retrieving $name"
        ex
    }
}

if($OLD_SID -eq $NEW_SID)
{
    log "Old SID $($OLD_SID) and new SID $($NEW_SID) are the same. Skipping new profile creation."
}
else
{
    # Remove aadBrokerPlugin from profile
$aadBrokerPath = (Get-ChildItem -Path "$($OLD_profilePath)\AppData\Local\Packages" -Recurse | Where-Object {$_.Name -match "Microsoft.AAD.BrokerPlugin_*"}).FullName
if($aadBrokerPath)
{
    log "Removing aadBrokerPlugin from profile..."
    Remove-Item -Path $aadBrokerPath -Recurse -Force
    log "aadBrokerPlugin removed"
}
else
{
    log "aadBrokerPlugin not found"
}

# Create new user profile
log "Creating $($NEW_SAMName) profile..."
Add-Type -TypeDefinition @"
using System;
using System.Security.Principal;
using System.Runtime.InteropServices;
namespace UserProfile {
    public static class Class {
        [DllImport("userenv.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern int CreateProfile(
            [MarshalAs(UnmanagedType.LPWStr)] String pszUserSid,
            [MarshalAs(UnmanagedType.LPWStr)] String pszUserName,
            [Out][MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszProfilePath,
            uint cchProfilePath
        );
    }
}
"@

$sb      = New-Object System.Text.StringBuilder(260)
$pathLen = $sb.Capacity

try {
    $CreateProfileReturn = [UserProfile.Class]::CreateProfile($NEW_SID, $NEW_SAMName, $sb, $pathLen)
} catch {
    Log $_.Exception.Message
}

switch ($CreateProfileReturn) {
    0 {
        Log "User profile created successfully at path: $($sb.ToString())"
    }
    -2147024713 {
        Log "User profile already exists."
    }
    default {
        Log "An error occurred when creating the user profile: $CreateProfileReturn"
        # show message box
        Show-MessageBox -Message "An error occurred when creating the user profile: $CreateProfileReturn" -Title "Error" -Icon "Error"
        shutdown -r -t 05
        exit 1
    }
}

# Check for new profile

$maxRetries = 5
$retryDelay = 10
$attempt = 0
$newProfile = $null

while ($attempt -lt $maxRetries -and $null -eq $newProfile)
{
    $newProfile = Get-CimInstance -ClassName Win32_UserProfile | Where-Object { $_.SID -eq $NEW_SID }

    if($null -eq $newProfile)
    {
        log "Profile not found yet, retrying in $retryDelay seconds..."
        Start-Sleep -Seconds $retryDelay
    }
    $attempt++
}

if($null -eq $newProfile)
{
    log "Profile not found after $maxRetries attempts. Forcing registration..."
    Start-Process -FilePath "C:\Windows\System32\runas.exe" -ArgumentList "/user:$NEW_SAMName cmd.exe /c exit" -NoNewWindow -Wait

    Start-Sleep -Seconds 3
    
    $newProfile = Get-CimInstance -ClassName Win32_UserProfile | Where-Object { $_.SID -eq $NEW_SID }
    if($null -eq $newProfile)
    {
        log "Profile still not found. Exiting script..."
        # show message box
        Show-MessageBox -Message "Profile still not found. Exiting script..." -Title "Error" -Icon "Error"
        shutdown -r -t 05
        exit 1
    }
}

log "Profile found. Proceeding with deletion."

# Ensure profile is not locked with active processes
$processes = Get-CimInstance -ClassName Win32_Process | Where-Object { $_.SessionId -eq $NEW_SID}

if($processes)
{
    log "Profile is currently in use by running processes.  Wainting 10 seconds before retrying deletion..."
    Start-Sleep -Seconds 10
}

# Delete the user profile
try
{
    Remove-CimInstance -InputObject $newProfile -Verbose | Out-Null
    log "User profile deleted."
}
catch
{
    log "Failed to delete user profile: $($_.Exception.Message)"
    # show message box
    Show-MessageBox -Message "Failed to delete user profile: $($_.Exception.Message)" -Title "Error" -Icon "Error"
    shutdown -r -t 05
    exit 1
}

# Change ownership of user profile
log "Changing ownership of user profile..."
$currentProfile = Get-CimInstance -ClassName Win32_UserProfile | Where-Object {$_.SID -eq $OLD_SID}
$changes = @{
    NewOwnerSID = $NEW_SID
    Flags = 0
}

try 
{
    $currentProfile | Invoke-CimMethod -MethodName ChangeOwner -Arguments $changes | Out-Null
    log "User profile ownership changed."
}
catch 
{
    $message = $_.Exception.Message
    log "Failed to change user profile ownership: $message"
    log "Exiting script..."
    # show message box
    Show-MessageBox -Message "Failed to change user profile ownership: $message" -Title "Error" -Icon "Error"
    shutdown -r -t 05
    exit 1
}

# Cleanup logon cache
function cleanupLogonCache()
{
    Param(
        [string]$logonCache = "HKLM:\SOFTWARE\Microsoft\IdentityStore\LogonCache",
        [string]$oldUPN = $OLD_UPN
    )
    log "Cleaning up logon cache..."
    $logonCacheGUID = (Get-ChildItem -Path $logonCache | Select-Object Name | Split-Path -Leaf).trim('{}')
    foreach($GUID in $logonCacheGUID)
    {
        $subKeys = Get-ChildItem -Path "$logonCache\$GUID" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name | Split-Path -Leaf
        if(!($subKeys))
        {
            log "No subkeys found for $GUID"
            continue
        }
        else
        {
            $subKeys = $subKeys.trim('{}')
            foreach($subKey in $subKeys)
            {
                if($subKey -eq "Name2Sid" -or $subKey -eq "SAM_Name" -or $subKey -eq "Sid2Name")
                {
                    $subFolders = Get-ChildItem -Path "$logonCache\$GUID\$subKey" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name | Split-Path -Leaf
                    if(!($subFolders))
                    {
                        log "Error - no sub folders found for $subKey"
                        continue
                    }
                    else
                    {
                        $subFolders = $subFolders.trim('{}')
                        foreach($subFolder in $subFolders)
                        {
                            $cacheUsername = Get-ItemPropertyValue -Path "$logonCache\$GUID\$subKey\$subFolder" -Name "IdentityName" -ErrorAction SilentlyContinue
                            if($cacheUsername -eq $oldUserName)
                            {
                                Remove-Item -Path "$logonCache\$GUID\$subKey\$subFolder" -Recurse -Force
                                log "Registry key deleted: $logonCache\$GUID\$subKey\$subFolder"
                                continue                                       
                            }
                        }
                    }
                }
            }
        }
    }
}

# run cleanupLogonCache
log "Running cleanupLogonCache..."
try
{
    cleanupLogonCache
    log "cleanupLogonCache completed"
}
catch
{
    $message = $_.Exception.Message
    log "Failed to run cleanupLogonCache: $message"
    log "Exiting script..."
    exit 1
}

# cleanup identity store cache
function cleanupIdentityStore()
{
    Param(
        [string]$idCache = "HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache",
        [string]$oldUserName = $OLD_UPN
    )
    log "Cleaning up identity store cache..."
    $idCacheKeys = (Get-ChildItem -Path $idCache | Select-Object Name | Split-Path -Leaf).trim('{}')
    foreach($key in $idCacheKeys)
    {
        $subKeys = Get-ChildItem -Path "$idCache\$key" -ErrorAction SilentlyContinue | Select-Object Name | Split-Path -Leaf
        if(!($subKeys))
        {
            log "No keys listed under '$idCache\$key' - skipping..."
            continue
        }
        else
        {
            $subKeys = $subKeys.trim('{}')
            foreach($subKey in $subKeys)
            {
                $subFolders = Get-ChildItem -Path "$idCache\$key\$subKey" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name | Split-Path -Leaf
                if(!($subFolders))
                {
                    log "No subfolders detected for $subkey- skipping..."
                    continue
                }
                else
                {
                    $subFolders = $subFolders.trim('{}')
                    foreach($subFolder in $subFolders)
                    {
                        $idCacheUsername = Get-ItemPropertyValue -Path "$idCache\$key\$subKey\$subFolder" -Name "UserName" -ErrorAction SilentlyContinue
                        if($idCacheUsername -eq $oldUserName)
                        {
                            Remove-Item -Path "$idCache\$key\$subKey\$subFolder" -Recurse -Force
                            log "Registry path deleted: $idCache\$key\$subKey\$subFolder"
                            continue
                        }
                    }
                }
            }
        }
    }
}

# run cleanup identity store cache if not domain joined
if($OLD_domainJoined -eq "NO")
{
    log "Running cleanupIdentityStore..."
    try
    {
        cleanupIdentityStore
        log "cleanupIdentityStore completed"
    }
    catch
    {
        $message = $_.Exception.Message
        log "Failed to run cleanupIdentityStore: $message"
        log "Exiting script..."
        ex
    }
}
else
{
    log "Machine is domain joined - skipping cleanupIdentityStore."
}

# update samname in identityStore LogonCache (this is required when displaynames are the same in both tenants, and new samname gets random characters added at the end)
function updateSamNameLogonCache()
{
    Param(
        [string]$logonCache = "HKLM:\SOFTWARE\Microsoft\IdentityStore\LogonCache",
        [string]$targetSAMName = $OLD_SAMName
    )

    if($NEW_SAMName -like "$($OLD_SAMName)_*" -or $NEW_SAMName -like "$($OLD_SAMName).*")
    {
        log "New user is $NEW_SAMName, which is the same as $OLD_SAMName with _##### appended to the end. Removing appended characters on SamName in LogonCache registry..."

        $logonCacheGUID = (Get-ChildItem -Path $logonCache | Select-Object Name | Split-Path -Leaf).trim('{}')
        foreach($GUID in $logonCacheGUID)
        {
            $subKeys = Get-ChildItem -Path "$logonCache\$GUID" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name | Split-Path -Leaf
            if(!($subKeys))
            {
                log "No subkeys found for $GUID"
                continue
            }
            else
            {
                $subKeys = $subKeys.trim('{}')
                foreach($subKey in $subKeys)
                {
                    if($subKey -eq "Name2Sid")
                    {
                        $subFolders = Get-ChildItem -Path "$logonCache\$GUID\$subKey" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name | Split-Path -Leaf
                        if(!($subFolders))
                        {
                            log "Error - no sub folders found for $subKey"
                            continue
                        }
                        else
                        {
                            $subFolders = $subFolders.trim('{}')
                            foreach($subFolder in $subFolders)
                            {
                                $detectedUserSID = Get-ItemProperty -Path "$logonCache\$GUID\$subKey\$subFolder" | Select-Object -ExpandProperty "Sid" -ErrorAction SilentlyContinue
                                if($detectedUserSID -eq $NEW_SID)
                                {
                                    Set-ItemProperty -Path "$logonCache\$GUID\$subKey\$subFolder" -Name "SAMName" -Value $targetSAMName -Force
                                    log "Attempted to update SAMName value (in Name2Sid registry folder) to '$targetSAMName'."
                                    continue                                       
                                }
                                else
                                {
                                    log "Detected Sid '$detectedUserSID' is for different user - skipping Sid in Name2Sid registry folder..."
                                }
                            }
                        }
                    }
                    elseif($subKey -eq "SAM_Name")
                    {
                        $subFolders = Get-ChildItem -Path "$logonCache\$GUID\$subKey" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name | Split-Path -Leaf
                        if(!($subFolders))
                        {
                            log "Error - no sub folders found for $subKey"
                            continue
                        }
                        else
                        {
                            $subFolders = $subFolders.trim('{}')
                            foreach($subFolder in $subFolders)
                            {
                                $detectedUserSID = Get-ItemProperty -Path "$logonCache\$GUID\$subKey\$subFolder" | Select-Object -ExpandProperty "Sid" -ErrorAction SilentlyContinue
                                if($detectedUserSID -eq $NEW_SID)
                                {
                                    Rename-Item "$logonCache\$GUID\$subKey\$subFolder" -NewName $targetSAMName -Force
                                    log "Attempted to update SAM_Name key name (in SAM_Name registry folder) to '$targetSAMName'."
                                    continue                                       
                                }
                                else
                                {
                                    log "Skipping different user in SAM_Name registry folder (User: $subFolder, SID: $detectedUserSID)..."
                                }
                            }
                        }
                    }
                    elseif($subKey -eq "Sid2Name")
                    {
                        $subFolders = Get-ChildItem -Path "$logonCache\$GUID\$subKey" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name | Split-Path -Leaf
                        if(!($subFolders))
                        {
                            log "Error - no sub folders found for $subKey"
                            continue
                        }
                        else
                        {
                            $subFolders = $subFolders.trim('{}')
                            foreach($subFolder in $subFolders)
                            {
                                if($subFolder -eq $NEW_SID)
                                {
                                    Set-ItemProperty -Path "$logonCache\$GUID\$subKey\$subFolder" -Name "SAMName" -Value $targetSAMName -Force
                                    log "Attempted to update SAM_Name value (in Sid2Name registry folder) to '$targetSAMName'."
                                    continue                                       
                                }
                                else
                                {
                                    log "Skipping different user SID ($subFolder) in Sid2Name registry folder..."
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    else
    {
        log "New username is $NEW_SAMName, which does not match older username ($OLD_SAMName) with _##### appended to end. SamName LogonCache registry will not be updated."
    }
}

# run updateSamNameLogonCache
log "Running updateSamNameLogonCache..."
try
{
    updateSamNameLogonCache
    log "updateSamNameLogonCache completed"
}
catch
{
    $message = $_.Exception.Message
    log "Failed to run updateSamNameLogonCache: $message"
    log "Exiting script..."
    exit 1
}

# update samname in identityStore Cache (this is required when displaynames are the same in both tenants, and new samname gets random characters added at the end)
function updateSamNameIdentityStore()
{
    Param(
        [string]$idCache = "HKLM:\Software\Microsoft\IdentityStore\Cache",
        [string]$targetSAMName = $OLD_SAMName
    )
    if($NEW_SAMName -like "$($OLD_SAMName)_*")
    {
        log "Cleaning up identity store cache..."
        $idCacheKeys = (Get-ChildItem -Path $idCache | Select-Object Name | Split-Path -Leaf).trim('{}')
        foreach($key in $idCacheKeys)
        {
            $subKeys = Get-ChildItem -Path "$idCache\$key" -ErrorAction SilentlyContinue | Select-Object Name | Split-Path -Leaf
            if(!($subKeys))
            {
                log "No keys listed under '$idCache\$key' - skipping..."
                continue
            }
            else
            {
                $subKeys = $subKeys.trim('{}')
                foreach($subKey in $subKeys)
                {
                    $subFolders = Get-ChildItem -Path "$idCache\$key\$subKey" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name | Split-Path -Leaf
                    if(!($subFolders))
                    {
                        log "No subfolders detected for $subkey- skipping..."
                        continue
                    }
                    else
                    {
                        $subFolders = $subFolders.trim('{}')
                        foreach($subFolder in $subFolders)
                        {
                            if($subFolder -eq $NEW_SID)
                            {
                                Set-ItemProperty -Path "$idCache\$key\$subKey\$subFolder" -Name "SAMName" -Value $targetSAMName -Force
                                log "Attempted to update SAMName value to $targetSAMName."
                            }
                            else
                            {
                                log "Skipping different user SID ($subFolder) in $subKey registry folder..."
                            }
                        }
                    }
                }
            }
        }
    }
    else
    {
        log "New username is $NEW_SAMName, which does not match older username ($OLD_SAMName) with _##### appended to end. SamName IdentityStore registry will not be updated."
    }
}

# run updateSamNameIdentityStore if not domain joined
if($OLD_domainJoined -eq "NO")
{
    log "Running updateSamNameIdentityStore..."
    try
    {
        updateSamNameIdentityStore
        log "updateSamNameIdentityStore completed"
    }
    catch
    {
        $message = $_.Exception.Message
        log "Failed to run updateSamNameIdentityStore: $message"
        log "Exiting script..."
        ex
    }
}
else
{
    log "Machine is domain joined - skipping updateSamNameIdentityStore."
}
}




# enable logon provider
reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\{60b78e88-ead8-445c-9cfd-0b87f74ea6cd}" /v "Disabled" /t REG_DWORD /d 0 /f | Out-Host
log "Enabled logon provider."

# set lock screen caption
if($config.targetTenant.tenantName)
{
    $tenant = $config.targetTenant.tenantName
}
else
{
    $tenant = $config.sourceTenant.tenantName
}
reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v "legalnoticecaption" /t REG_SZ /d "Welcome to $($tenant)" /f | Out-Host 
reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v "legalnoticetext" /t REG_SZ /d "Please log in with your new email address" /f | Out-Host
log "Lock screen caption set."


log "Reboot.ps1 complete"
Stop-Transcript
shutdown -r -t 00


