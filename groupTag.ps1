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

Start-Transcript -Path "$($config.localPath)\groupTag.log" -Append -Verbose
log "Starting groupTag.ps1"

# Authenticate to Microsoft Graph
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

# Get entra device Id
$hostname = $env:COMPUTERNAME
$intuneId = (Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/beta/devices?`$filter=deviceName eq '$($hostname)'" -Headers $headers).value
$entraDeviceId = $intuneId.azureADDeviceId
$entraObjectId = (Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/beta/devices?`$filter=deviceId eq '$($entraDeviceId)'" -Headers $headers).value.id


$tag1 = (Get-ItemProperty -Path "HKLM:\SOFTWARE\IntuneMigration" -Name "OLD_groupTag").OLD_groupTag
$tag2 = $config.groupTag

if([string]::IsNullOrEmpty($tag1))
{
    $groupTag = $tag2
    log "GroupTag is $($groupTag)"
}
elseif([string]::IsNullOrEmpty($tag2))
{
    $groupTag = $tag1
    log "GroupTag is $($groupTag)"
}
else
{
    $groupTag = $null
    log "GroupTag not found"
}

if([string]::IsNullOrEmpty($groupTag))
{
    log "GroupTag not found.  Exiting."
    Exit
}
else
{
    log "Updating groupTag to $($groupTag) on Entra device $($entraObjectId)"
    $entraDeviceObject = Invoke-RestMethod -Uri "https://graph.microsoft.com/beta/devices/$($entraObjectId)" -Headers $headers
    $physicalIds = $entraDeviceObject.physicalIds
    $newTag = "[OrderID]:$groupTag"
    $physicalIds += $newTag

    $body = @{
        physicalIds = $physicalIds
    } | ConvertTo-Json
}

try 
{
    Invoke-RestMethod -Method Patch -Uri "https://graph.microsoft.com/beta/devices/$($entraObjectId)" -Headers $headers -Body $body
    log "GroupTag updated to $($groupTag) on Entra device $($entraObjectId)"
}
catch
{
    log "Error updating groupTag on Entra device $($entraObjectId)"
    exit 1    
}

Stop-Transcript
