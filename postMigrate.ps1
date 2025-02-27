<# POSTMIGRATE.PS1
Synopsis
PostMigrate.ps1 is run after the migration reboots have completed and the user signs into the PC.
DESCRIPTION
This script is used to update the device group tag in Entra ID and set the primary user in Intune and migrate the bitlocker recovery key.  The device is then registered with AutoPilot.
USE
.\postMigrate.ps1
.OWNER
Steve Weiner
.CONTRIBUTORS
Logan Lautt

#>

$ErrorActionPreference = "SilentlyContinue"

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

# FUNCTION: msGraphAuthenticate
# DESCRIPTION: Authenticates to Microsoft Graph.
function msGraphAuthenticate()
{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string]$tenantName,
        [Parameter(Mandatory=$true)]
        [string]$clientId,
        [Parameter(Mandatory=$true)]
        [string]$clientSecret
    )
    $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $headers.Add("Content-Type", "application/x-www-form-urlencoded")
    $body = "grant_type=client_credentials&scope=https://graph.microsoft.com/.default"
    $body += -join ("&client_id=" , $clientId, "&client_secret=", $clientSecret)
    $response = Invoke-RestMethod "https://login.microsoftonline.com/$tenantName/oauth2/v2.0/token" -Method 'POST' -Headers $headers -Body $body
    # Get token from OAuth response

    $token = -join ("Bearer ", $response.access_token)

    # Reinstantiate headers
    $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $headers.Add("Authorization", $token)
    $headers.Add("Content-Type", "application/json")
    $headers = @{'Authorization'="$($token)"}
    return $headers
}

# Import settings from the JSON file
$config = Get-Content "C:\ProgramData\IntuneMigration\config.json" | ConvertFrom-Json

# Start Transcript
Start-Transcript -Path "$($config.logPath)\postMigrate.log" -Verbose
log "Starting PostMigrate.ps1..."

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

# disable postMigrate task
log "Disabling postMigrate task..."
Disable-ScheduledTask -TaskName "postMigrate"
log "postMigrate task disabled."

# enable displayLastUserName
log "Enabling displayLastUserName..."
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DontDisplayLastUserName" -Value 0 -Verbose
log "Enabled displayLastUserName."

# authenticate to target tenant if exists
if($config.targetTenant.tenantName)
{
    log "Authenticating to target tenant..."
    $headers = msGraphAuthenticate -tenantName $config.targetTenant.tenantName -clientID $config.targetTenant.clientID -clientSecret $config.targetTenant.clientSecret
    log "Authenticated to target tenant."
}
else
{
    log "No target tenant specified.  Authenticating into source tenant."
    $headers = msGraphAuthenticate -tenantName $config.sourceTenant.tenantName -clientID $config.sourceTenant.clientID -clientSecret $config.sourceTenant.clientSecret
    log "Authenticated to source tenant."
}

# Get current device Intune and Entra attributes
log "Getting current device attributes..."
$intuneDeviceId = ((Get-ChildItem "Cert:\LocalMachine\My" | Where-Object {$_.Issuer -match "Microsoft Intune MDM Device CA"} | Select-Object Subject).Subject).TrimStart("CN=")
$entraDeviceId = ((Get-ChildItem "Cert:\LocalMachine\My" | Where-Object {$_.Issuer -match "MS-Organization-Access"} | Select-Object Subject).Subject).TrimStart("CN=")
$entraId = (Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/beta/devices?`$filter=deviceid eq '$entraDeviceId'" -Headers $headers).value.id
log "Intune Device ID is $($intuneDeviceId)"
log "Entra Object ID is $($entraId)"

# setPrimaryUser
[string]$targetUserId = (Get-ItemProperty -Path "HKLM:\SOFTWARE\IntuneMigration" -Name "NEW_entraUserID").NEW_entraUserID
[string]$sourceUserId = (Get-ItemProperty -Path "HKLM:\SOFTWARE\IntuneMigration" -Name "OLD_entraUserID").OLD_entraUserID
    
if([string]::IsNullOrEmpty($targetUserId))
{
    log "Target user not found- proceeding with source user $($sourceUserId)."
    $userId = $sourceUserId
}
else
{
    log "Target user found- proceeding with target user $($targetUserId)."
    $userId = $targetUserId
}
$userUri = "https://graph.microsoft.com/beta/users/$userId"
$id = "@odata.id"
$JSON = @{ $id=$userUri } | ConvertTo-Json
try
{
    Invoke-RestMethod -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$intuneDeviceId/users/`$ref" -Method Post -Headers $headers -Body $JSON -ContentType "application/json"
    log "Primary user set to $($userId)."
}
catch
{
    $message = $_.Exception.Message
    log "Error setting primary user: $message"
}

# updateGroupTag
$tag1 = (Get-ItemProperty -Path "HKLM:\SOFTWARE\IntuneMigration" -Name "OLD_groupTag").OLD_groupTag
$tag2 = $config.groupTag

if([string]::IsNullOrEmpty($tag1))
{
    $groupTag = $tag2
}
elseif([string]::IsNullOrEmpty($tag2)) {
    $groupTag = $tag1
}
else
{
    $groupTag = $null
    log "Group tag not found"
}

if(![string]::IsNullOrEmpty($groupTag))
{
    log "Updating group tag to $($groupTag) for Entra Device $($entraId)..."
    $entraDeviceObject = Invoke-RestMethod -Uri "https://graph.microsoft.com/beta/devices/$entraId" -Headers $headers
    $physicalIds = $entraDeviceObject.physicalIds
    $newTag = "[OrderID]:$groupTag"
    $physicalIds += $newTag

    $body = @{
        physicalIds = $physicalIds
    } | ConvertTo-Json
        
    try
    {
        Invoke-RestMethod -Uri "https://graph.microsoft.com/beta/devices/$entraId" -Method Patch -Headers $headers -Body $body
        log "Group tag updated to $($groupTag)."
    }
    catch
    {
        $message = $_.Exception.Message
        log "Error updating group tag: $message"
    }
}
else
{
    log "No group tag found."
}

schtasks.exe /create /xml "$($config.localPath)\groupTag.xml" /tn GroupTag /f | Out-Host


# FUNCTION: migrateBitlockerKey
function migrateBitlockerKey()
{
    Param(
        [string]$mountPoint = "C:",
        [PSCustomObject]$bitLockerVolume = (Get-BitLockerVolume -MountPoint $mountPoint),
        [string]$keyProtectorId = ($bitLockerVolume.KeyProtector | Where-Object {$_.KeyProtectorType -eq "RecoveryPassword"}).KeyProtectorId
    )
    if($bitLockerVolume.KeyProtector.count -gt 0)
    {
        BackupToAAD-BitLockerKeyProtector -MountPoint $mountPoint -KeyProtectorId $keyProtectorId
        log "Bitlocker recovery key migrated."
    }
    else
    {
        log "No bitlocker recovery key found."
    }
}

# FUNCTION: decryptDrive
function decryptDrive()
{
    Param(
        [string]$mountPoint = "C:"
    )
    Disable-BitLocker -MountPoint $mountPoint
    log "Drive decrypted."
}

# check bitlocker settings in config file and either migrate or decrypt
log "Checking bitlocker settings..."
if($config.bitlocker -eq "MIGRATE")
{
    log "Migrating bitlocker recovery key..."
    try
    {
        migrateBitlockerKey
        log "Bitlocker recovery key migrated."
    }
    catch
    {
        $message = $_.Exception.Message
        log "Error migrating bitlocker recovery key: $message"
    }
}
elseif($config.bitlocker -eq "DECRYPT")
{
    log "Decrypting drive..."
    try
    {
        decryptDrive
        log "Drive decrypted."
    }
    catch
    {
        $message = $_.Exception.Message
        log "Error decrypting drive: $message"
    }
}
else
{
    log "Bitlocker settings not found."
}

# Register device in Autopilot
log "Registering device in Autopilot..."

# Get hardware info
$serialNumber = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber
$hardwareId = ((Get-CimInstance -Namespace root/cimv2/mdm/dmmap -ClassName MDM_DevDetail_Ext01 -Filter "InstanceID='Ext' AND ParentID='./DevDetail'").DeviceHardwareData)
if([string]::IsNullOrEmpty($groupTag))
{
    $tag = ""
}
else
{
    $tag = $groupTag
}

# Construct JSON
$json = @"
{
    "@odata.type": "#microsoft.graph.importedWindowsAutopilotDeviceIdentity",
    "groupTag":"$tag",
    "serialNumber":"$serialNumber",
    "productKey":"",
    "hardwareIdentifier":"$hardwareId",
    "assignedUserPrincipalName":"",
    "state":{
        "@odata.type":"microsoft.graph.importedWindowsAutopilotDeviceIdentityState",
        "deviceImportStatus":"pending",
        "deviceRegistrationId":"",
        "deviceErrorCode":0,
        "deviceErrorName":""
    }
}
"@

# Post device
try
{
    Invoke-RestMethod -Method Post -Body $json -ContentType "application/json" -Uri "https://graph.microsoft.com/beta/deviceManagement/importedWindowsAutopilotDeviceIdentities" -Headers $headers
    log "Device registered in Autopilot."
}
catch
{
    $message = $_.Exception.Message
    log "Error registering device in Autopilot: $message"
}

# reset lock screen caption
# Specify the registry key path
$registryKeyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"

# Specify the names of the registry entries to delete
$entryNames = @("legalnoticecaption", "legalnoticetext")

# Loop through each entry and delete it
foreach ($entryName in $entryNames) {
    try {
        Remove-ItemProperty -Path $registryKeyPath -Name $entryName -Force
        log "Deleted registry entry: $entryName"
    } catch {
        log "Failed to delete registry entry: $entryName. Error: $_"
    }
}


<# Cleanup
log "Cleaning up migration files..."
Remove-Item -Path $config.localPath -Recurse -Force
log "Migration files cleaned up."#>

# Remove scheduled tasks
log "Removing scheduled tasks..."
$tasks = @("reboot", "postMigrate")
foreach($task in $tasks)
{
    Unregister-ScheduledTask -TaskName $task -Confirm:$false
    log "$task task removed."
}

# Remove MigrationUser
log "Removing MigrationUser..."
try 
{
    Remove-LocalUser -Name "MigrationInProgress" -Confirm:$false
    log "MigrationUser removed."    
}
catch 
{
    $message = $_.Exception.Message
    log "Error removing MigrationUser: $message"
}


# End Transcript
log "Device migration complete"
Stop-Transcript
