<#
SYNOPSIS
    This solution will automate the migration of devices from one Intune tenant to another Intune tenant.  Devices can be Hybrid Entra Joined, Active Directory Domain Joined, or Entra Joined.

DESCRIPTION
    Intune Device Migration Solution leverages the Microsoft Graph API to automate the migration of devices from one Intune tenant to another Intune tenant.  Devices can be hybrid AD Joined or Azure AD Joined.  The solution will also migrate the device's primary user profile data and files.  The solution leverages Windows Configuration Designer to create a provisioning package containing a Bulk Primary Refresh Token (BPRT).  Tasks are set to run after the user signs into the PC with destination tenant credentials to update Intune attributes including primary user, Entra ID device group tag, and device category.  In the last step, the device is registered to the destination tenant Autopilot service.  

NOTES
    File Name      : startMigrate.ps1
.OWNER
Steve Weiner
.CONTRIBUTORS
    Logan Lautt
    Jesse Weimer
#>

Add-Type -AssemblyName System.Windows.Forms

$ErrorActionPreference = "SilenctlyContinue"

# log function

function Log {
    param (
        [string]$message
    )
    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $message = "$time - $message"
    Write-Output $message
}

# Graph authenticate function
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

# Generate password function
function generatePassword()
{
    Param(
        [int]$length = 12
    )
    $charSet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()-_=+[]{}|;:',<.>/?"
    $securePassword = New-Object -TypeName System.Security.SecureString
    1..$length | ForEach-Object {
        $random = $charSet[(Get-Random -Minimum 0 -Maximum $charSet.Length)]
        $securePassword.AppendChar($random)
    }
    return $securePassword
}

# Import configuration file
$config = Get-Content ".\config.json" | ConvertFrom-Json
$regPath = $config.regPath

# Start logging
Start-Transcript -Path "$($config.logPath)\startMigrate.log" -Append -Verbose
log "Starting Intune Device Migration V8..."

# Check if local path exists and create if it does not
$localPath = "$($config.localPath)"
if (-not (Test-Path $localPath)) 
{
    log "Creating local path $localPath"
    New-Item -Path $localPath -ItemType Directory
}
else
{
    log "Local path $localPath already exists"
}

# Set install tag if deployed from Intune
log "Setting Intune detection rule"
New-Item -ItemType File -Path "$localPath\IntuneDetectionRule.txt" -Force
log "Intune detection rule set"

# Check context 
$context = whoami
log "Running as $context"

# Copy package files to local path
log "Copying package files to local path"
Copy-Item -Path ".\*" -Destination $localPath -Recurse -Force

# Authenticate to source tenant
log "Checking configuration file for source tenant..."
if([string]::IsNullOrEmpty($config.sourceTenant.tenantName))
{
    log "Source tenant not found in configuration file"
    exit
}
else
{
    log "Source tenant found in configuration file"
    try
    {
        log "Authenticating to source tenant..."
        $sourceHeaders = msGraphAuthenticate -tenantName $config.sourceTenant.tenantName -clientId $config.sourceTenant.clientId -clientSecret $config.sourceTenant.clientSecret
        log "Authenticated to source tenant"
    }
    catch
    {
        $message = $_.Exception.Message
        log "Failed to authenticate to source tenant: $message"
        exit
    }
}

# Authenticate to destination tenant
log "Checking configuration file for destination tenant..."
if([string]::IsNullOrEmpty($config.targetTenant.tenantName))
{
    log "Destination tenant not found in configuration file"
    $targetHeaders = $null
}
else
{
    log "Destination tenant found in configuration file"
    try
    {
        log "Authenticating to destination tenant..."
        $targetHeaders = msGraphAuthenticate -tenantName $config.targetTenant.tenantName -clientId $config.targetTenant.clientId -clientSecret $config.targetTenant.clientSecret
        log "Authenticated to destination tenant"
    }
    catch
    {
        $message = $_.Exception.Message
        log "Failed to authenticate to destination tenant: $message"
        [System.Windows.Forms.MessageBox]::Show("Failed to authenticate to destination tenant: $message", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        exit 1
    }
}

# Check Microsoft account connection registry key
log "Checking Microsoft account connection registry key..."
$accountConnectionPath = "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Accounts"
$accountConnectionKey = "Registry::$accountConnectionPath"
$accountConnectionName = "AllowMicrosoftAccountConnection"
$accountConnectionValue = Get-ItemProperty -Path $accountConnectionKey -Name $accountConnectionName -ErrorAction SilentlyContinue
if(!($accountConnectionValue))
{
    log "Microsoft account connection registry key not found; creating..."
    reg.exe add $accountConnectionPath /v $accountConnectionName /t REG_DWORD /d 1 /f | Out-Host
    log "Microsoft account connection registry key created"
}
elseif($accountConnectionValue -ne 1)
{
    log "Microsoft account connection registry key found; updating..."
    reg.exe add $accountConnectionPath /v $accountConnectionName /t REG_DWORD /d 1 /f | Out-Host
    log "Microsoft account connection registry key updated"
}
else
{
    log "Microsoft account connection registry key found"
}

# Create the PC object
[string]$hostname = $env:COMPUTERNAME
[string]$azureAdJoined = (dsregcmd.exe /status | Select-String "AzureAdJoined").ToString().Split(":")[1].Trim()
[string]$domainJoined = (dsregcmd.exe /status | Select-String "DomainJoined").ToString().Split(":")[1].Trim()
[string]$certPath = "Cert:\LocalMachine\My"
[string]$intuneIssuer = "Microsoft Intune MDM Device CA"
[string]$azureIssuer = "MS-Organization-Access"
[string]$autopilotRegPath = "HKLM:\SOFTWARE\Microsoft\Provisioning\Diagnostics\Autopilot"
[string]$autopilotRegName = "CloudAssignedMdmId"
[string]$autopilotRegValue = Get-ItemProperty -Path $autopilotRegPath -Name $autopilotRegName -ErrorAction SilentlyContinue
[bool]$mdm = $false

# Check if device is Intune managed
$intuneCert = Get-ChildItem -Path $certPath | Where-Object {$_.Issuer -match $intuneIssuer}
log "Checking for Intune certificate..."
if($intuneCert)
{
    log "Intune certificate found"
    $mdm = $true
    $intuneId = (($intuneCert | Select-Object Subject).Subject).TrimStart("CN=")
    log "Intune ID: $intuneId"
    log "$hostname is Intune managed"
}
else
{
    log "Device is not Intune managed"
    $intuneId = $null
    log "Intune ID: $intuneId"
}

# Check if device is Autopilot registered
log "Checking for Autopilot registration..."
if($autopilotRegValue)
{
    log "Autopilot registration found"
    $mdm = $true
    $autopilotId = (Get-ItemProperty -Path "$($autopilotRegPath)\EstablishedCorrelations" -Name "ZtdRegistrationId").ZtdRegistrationId
    log "Autopilot ID: $autopilotId"
}
else
{
    log "Autopilot registration not found"
    $autopilotId = $null
    log "Autopilot ID: $autopilotId"
}

# Check if device is Azure AD joined
log "Checking for Azure AD join..."
if($azureAdJoined -eq "Yes")
{
    log "$hostname is Azure AD joined"
    $azureAdDeviceId = ((Get-ChildItem -Path $certPath | Where-Object {$_.Issuer -match $azureIssuer} | Select-Object Subject).Subject).TrimStart("CN=")
    try 
    {
        $azureAdId = (Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/beta/devices?$filter=deviceId eq '$azureAdDeviceId'" -Headers $sourceHeaders).value.id
        log "Azure AD ID: $azureAdId"
    }
    catch 
    {
        $message = $_.Exception.Message
        log "Failed to get Azure AD ID. Error: $message"
        $azureAdId = $null
        log "Azure AD ID: $azureAdId"
    }
}
else
{
    log "$hostname is not Azure AD joined"
    $azureAdId = $null
    log "Azure AD ID: $azureAdId"
}

# Check if device is domain joined
log "Checking for domain join..."
if($domainJoined -eq "Yes")
{
    log "$hostname is domain joined"
    $localDomain = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "Domain"
    log "Domain: $localDomain"
}
else
{
    log "$hostname is not domain joined"
    $localDomain = $null
    log "Domain: $localDomain"
}

$pc = @{
    hostname = $hostname
    intuneId = $intuneId
    azureAdId = $azureAdId
    localDomain = $localDomain
    autopilotId = $autopilotId
    domainJoined = $domainJoined
    azureAdJoined = $azureAdJoined
    mdm = $mdm
}

# Write PC object to registry
log "Writing PC object to registry..."
foreach($x in $pc.Keys)
{
    $pcName = "OLD_$($x)"
    $pcValue = $($pc[$x])
    # Check if value is null or empty
    if([string]::IsNullOrEmpty($pcValue))
    {
        log "$pcName is null or empty"
    }
    else
    {
        log "$($pcName): $pcValue"
        reg.exe add $regPath /v $pcName /t REG_SZ /d $pcValue /f | Out-Null
        log "$pcName written to registry with value: $pcValue"
    }
}

# get current user info
[string]$domainJoined = $pc.domainJoined
[string]$azureAdJoined = $pc.azureAdJoined
[string]$userName = (Get-CimInstance -ClassName Win32_ComputerSystem | Select-Object UserName).UserName
[string]$SID = (New-Object System.Security.Principal.NTAccount($userName)).Translate([System.Security.Principal.SecurityIdentifier]).Value
[string]$profilePath = (Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($SID)" -Name "ProfileImagePath")
[string]$SAMName = ($userName).Split("\")[1]
    
# If PC is NOT domain joined, get UPN from cache
log "Attempting to get current user's UPN..."
# If PC is Azure AD joined, get user ID from Graph
if($azureAdJoined -eq "YES")
{
    $upn = (Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache\$($SID)\IdentityCache\$($SID)" -Name "UserName")
    log "System is Entra ID Joined - detected IdentityCache UPN value: $upn. Querying graph..."
    $entraUserId = (Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/beta/users/$($upn)" -Headers $sourceHeaders).id
    if($entraUserId)
    {
        log "Successfully obtained Entra User ID: $entraUserId."
        log "Entra ID: $entraUserId"
    }
    else
    {
        log "Could not obtain Entra User ID from UPN value: $upn."
        $entraUserId = $null
        log "Entra ID: $entraUserId"
    }
}
else
{
    log "System is not Entra joined - setting UPN and Entra User ID values to Null."
    $upn = $null
    $entraUserId = $null
}

$currentUser = @{
    userName = $userName
    upn = $upn
    entraUserId = $entraUserId
    profilePath = $profilePath
    SAMName = $SAMName
    SID = $SID
}
# Write user object to registry
foreach($x in $currentUser.Keys)
{
    $currentUserName = "OLD_$($x)"
    $currentUserValue = $($currentUser[$x])
    # Check if value is null or empty
    if(![string]::IsNullOrEmpty($currentUserValue))
    {
        log "Writing $($currentUserName) with value $($currentUserValue)..."
        try
        {
            reg.exe add $regPath /v $currentUserName /t REG_SZ /d $currentUserValue /f | Out-Null
            log "Successfully wrote $($currentUserName) with value $($currentUserValue)."
        }
        catch
        {
            $message = $_.Exception.Message
            log "Failed to write $($currentUserName) with value $($currentUserValue).  Error: $($message)."
        }
    }
}


# USER SIGN IN TO VERIFY CREDENTIALS AND GET TARGET TENANT SID
$installedNuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue
if(-not($installedNuget))
{
    log "NuGet package provider not installed.  Installing..."
    Install-PackageProvider -Name NuGet -Force
    log "NuGet package provider installed successfully."
}
else
{
    log "NuGet package provider already installed."
}
# Check for Az.Accounts module
$modules = ("Az.Accounts","RunAsUser")
foreach($module in $modules)
{
    $installedModule = Get-InstalledModule -Name $module -ErrorAction SilentlyContinue
    if(-not($installedModule))
    {
        log "$module module not installed.  Installing..."
        Install-Module -Name $module -Force
        log "$module module installed successfully."
    }
    else
    {
        log "$module module already installed."
    }
}
$scriptBlock = {
    Import-Module Az.Accounts

    #Get Token form OAuth
    Clear-AzContext -Force
    Update-AzConfig -EnableLoginByWam $false -LoginExperienceV2 Off
    Connect-AzAccount
    $theToken = Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com/"

    #Get Token form OAuth
    $token = -join("Bearer ", $theToken.Token)

    #Reinstantiate headers
    $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $headers.Add("Authorization", $token)
    $headers.Add("Content-Type", "application/json")

    $newUserObject = Invoke-RestMethod -Uri "https://graph.microsoft.com/beta/me" -Headers $headers -Method "GET"

    $newUser = @{
        upn = $newUserObject.userPrincipalName
        entraUserId = $newUserObject.id
        SAMName = $newUserObject.userPrincipalName.Split("@")[0]
        SID = $newUserObject.securityIdentifier
    } | ConvertTo-JSON

    $newUser | Out-File "C:\Users\Public\Documents\newUserInfo.json"
}
$newUserPath = "C:\Users\Public\Documents\newUserInfo.json"
$timeout = 300
$checkInterval = 5
$elapsedTime = 0
Invoke-AsCurrentUser -ScriptBlock $scriptBlock -UseWindowsPowerShell
while($elapsedTime -lt $timeout)
{
    if(Test-Path $newUserPath)
    {
        log "New user found.  Continuing with script..."
        $elapsedTime = $timeout
        break
    }
    else
    {
        log "New user info not present.  Waiting for user to sign in..."
        Start-Sleep -Seconds $checkInterval
        $elapsedTime += $checkInterval
    }
}
if(Test-Path $newUserPath)
{
    $newUserInfo = Get-Content -Path "C:\Users\Public\Documents\newUserInfo.json" | ConvertFrom-JSON

    $newUser = @{
        entraUserID = $newUserInfo.entraUserId
        SID = $newUserInfo.SID
        SAMName = $newUserInfo.SAMName
        UPN = $newUserInfo.upn
    }
    foreach($x in $newUser.Keys)
    {
        $newUserName = "NEW_$($x)"
        $newUserValue = $($newUser[$x])
        if(![string]::IsNullOrEmpty($newUserValue))
        {
            log "Writing $($newUserName) with value $($newUserValue)..."
            try
            {
                reg.exe add "HKLM\SOFTWARE\IntuneMigration" /v $newUserName /t REG_SZ /d $newUserValue /f | Out-Null
                log "Successfully wrote $($newUserName) with value $($newUserValue)."
            }
            catch
            {
                $message = $_.Exception.Message
                log "Failed to write $($newUserName) with value $($newUserValue).  Error: $($message)."
            }
        }
    }
    Write-Host "User found. Continuing with script..."
    Remove-Item -Path $newUserPath -Force -Recurse
}
else
{
    log "User not found.  Exiting script."
    [System.Windows.Forms.MessageBox]::Show("Please enter the VM name and select the Windows 11 version", "Hyper Hyper-V", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
    exit 1
}


# remove MDM certificate
if($intuneCert)
{
    log "Removing MDM certificate..."
    $intuneCert | Remove-Item
    log "MDM certificate removed"
}
else
{
    log "MDM certificate not found"
}

# remove mdm enrollment
# Remove MDM enrollment
if($pc.mdm -eq $true)
{
    log "Removing MDM enrollment..."
    $enrollmentPath = "HKLM:\SOFTWARE\Microsoft\Enrollments"
    $enrollments = Get-ChildItem -Path $enrollmentPath
    foreach($enrollment in $enrollments)
    {
        $object = Get-ItemProperty Registry::$enrollment
        $enrollPath = $enrollmentPath + $object.PSChildName
        $key = Get-ItemProperty -Path $enrollPath -Name "DiscoveryServiceFullURL"
        if($key)
        {
            log "Removing MDM enrollment $($enrollPath)..."
            Remove-Item -Path $enrollPath -Recurse
            log "MDM enrollment removed successfully."
        }
        else
        {
            log "MDM enrollment not present."
        }
    }
    $enrollId = $enrollPath.Split("\")[-1]
    $additionalPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Enrollments\Status\$($enrollID)",
        "HKLM:\SOFTWARE\Microsoft\EnterpriseResourceManager\Tracked\$($enrollID)",
        "HKLM:\SOFTWARE\Microsoft\PolicyManager\AdmxInstalled\$($enrollID)",
        "HKLM:\SOFTWARE\Microsoft\PolicyManager\Providers\$($enrollID)",
        "HKLM:\SOFTWARE\Microsoft\Provinsioning\OMADM\Accounts\$($enrollID)",
        "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Logger\$($enrollID)",
        "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Sessions\$($enrollID)"
    )
    foreach($path in $additionalPaths)
    {
        if(Test-Path $path)
        {
            log "Removing $($path)..."
            Remove-Item -Path $path -Recurse
            log "$($path) removed successfully."
        }
        else
        {
            log "$($path) not present."
        }
    }
}
else
{
    log "MDM enrollment not present."
}


# Set migration tasks
$tasks = @("reboot","postMigrate")
foreach($task in $tasks)
{
    $taskPath = "$($localPath)\$($task).xml"
    if([string]::IsNullOrEmpty($taskPath))
    {
        log "$($task) task not found."
    }
    else
    {
        log "Setting $($task) task..."
        try
        {
            schtasks.exe /create /xml $taskPath /tn $task /f | Out-Host
            log "$($task) task set successfully."
        }
        catch
        {
            $message = $_.Exception.Message
            log "Failed to set $($task) task. Error: $message"
            log "Exiting script."
            [System.Windows.Forms.MessageBox]::Show("Failed to set $($task) task. Error: $message", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            exit 1
        }
    }
}

# Leave Azure AD / Entra Join
if($pc.azureAdJoined -eq "YES")
{
    log "PC is Azure AD Joined.  Leaving Azure AD..."
    try
    {
        Start-Process -FilePath "C:\Windows\System32\dsregcmd.exe" -ArgumentList "/leave"
        log "PC left Azure AD successfully."
    }
    catch
    {
        $message = $_.Exception.Message
        log "Failed to leave Azure AD. Error: $message"
        log "Exiting script."
        [System.Windows.Forms.MessageBox]::Show("Failed to leave Azure AD. Error: $message", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
}
else
{
    log "PC is not Azure AD Joined."
}

# Leave Domain/Hybrid Join
$migrateAdmin = "MigrationInProgress"
$adminPW = generatePassword
$adminGroup = Get-CimInstance -Query "Select * From Win32_Group Where LocalAccount = True And SID = 'S-1-5-32-544'"
$adminGroupName = $adminGroup.Name
New-LocalUser -Name $migrateAdmin -Password $adminPW -PasswordNeverExpires
Add-LocalGroupMember -Group $adminGroupName -Member $migrateAdmin

if($pc.domainJoined -eq "YES")
{
    [string]$hostname = $pc.hostname,
    [string]$localDomain = $pc.localDomain

    # Check for line of sight to domain controller
    $pingCount = 4
    $pingResult = Test-Connection -ComputerName $localDomain -Count $pingCount
    if($pingResult.StatusCode -eq 0)
    {
        log "$($hostname) has line of sight to domain controller.  Attempting to break..."
        $adapter = Get-NetAdapter | Where-Object {$_.Status -eq 'Up'} | Select-Object -ExpandProperty InterfaceAlias
        Set-DnsClientServerAddress -InterfaceAlias $adapter -ServerAddresses ("8.8.8.8","8.8.4.4")
        log "Successfully broke line of sight to domain controller."
    }
    else
    {
        log "$($hostname) has no line of sight to domain controller."
    }
    log "Checking $migrateAdmin status..."
    [bool]$acctStatus = (Get-LocalUser -Name $migrateAdmin).Enabled
    if($acctStatus -eq $false)
    {
        log "$migrateAdmin is disabled; setting password and enabling..."
        Get-LocalUser -Name $migrateAdmin | Enable-LocalUser
        log "Successfully enabled $migrateAdmin."
    }
    else
    {
        log "$migrateAdmin is already enabled."
    }
    try
    {
        $instance = Get-CimInstance -ClassName 'Win32_ComputerSystem'
        $invCimParams = @{
            MethodName = 'UnjoinDomainOrWorkGroup'
            Arguments = @{ FUnjoinOptions=0;Username="$hostname\$migrateAdmin";Password="$adminPW" }
        }
        $instance | Invoke-CimMethod @invCimParams
        log "Successfully unjoined $hostname from domain."
    }
    catch
    {
        $message = $_.Exception.Message
        log "Failed to unjoin $hostname from domain. Error: $message"
        log "Exiting script."
        [System.Windows.Forms.MessageBox]::Show("Failed to unjoin $hostname from domain. Error: $message", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
}
else
{
    log "PC is not domain joined."
}

# FUNCTION: removeSCCM
# DESCRIPTION: Removes the SCCM client from the device.
function removeSCCM()
{
    [CmdletBinding()]
    Param(
        [string]$CCMpath = "C:\Windows\ccmsetup\ccmsetup.exe",
        [array]$services = @("CcmExec","smstsmgr","CmRcService","ccmsetup"),
        [string]$CCMProcess = "ccmsetup",
        [string]$servicesRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\",
        [string]$ccmRegPath = "HKLM:\SOFTWARE\Microsoft\CCM",
        [array]$sccmKeys = @("CCM","SMS","CCMSetup"),
        [string]$CSPPath = "HKLM:\SOFTWARE\Microsoft\DeviceManageabilityCSP",
        [array]$sccmFolders = @("C:\Windows\ccm","C:\Windows\ccmsetup","C:\Windows\ccmcache","C:\Windows\ccmcache2","C:\Windows\SMSCFG.ini",
        "C:\Windows\SMS*.mif"),
        [array]$sccmNamespaces = @("ccm","sms")
    )
    
    # Remove SCCM client
    log "Removing SCCM client..."
    if(Test-Path $CCMpath)
    {
        log "Uninstalling SCCM client..."
        Start-Process -FilePath $CCMpath -ArgumentList "/uninstall" -Wait
        if($CCMProcess)
        {
            log "SCCM client still running; killing..."
            Stop-Process -Name $CCMProcess -Force -ErrorAction SilentlyContinue
            log "Killed SCCM client."
        }
        else
        {
            log "SCCM client uninstalled successfully."
        }
        # Stop SCCM services
        foreach($service in $services)
        {
            $serviceStatus = Get-Service -Name $service -ErrorAction SilentlyContinue
            if($serviceStatus)
            {
                log "Stopping $service..."
                Stop-Service -Name $service -Force -ErrorAction SilentlyContinue
                log "Stopped $service."
            }
            else
            {
                log "$service not found."
            }
        }
        # Remove WMI Namespaces
        foreach($namespace in $sccmNamespaces)
        {
            Get-WmiObject -Query "SELECT * FROM __Namespace WHERE Name = '$namespace'" -Namespace "root" | Remove-WmiObject
        }
        # Remove SCCM registry keys
        foreach($service in $services)
        {
            $serviceKey = $servicesRegPath + $service
            if(Test-Path $serviceKey)
            {
                log "Removing $serviceKey registry key..."
                Remove-Item -Path $serviceKey -Recurse -Force -ErrorAction SilentlyContinue
                log "Removed $serviceKey registry key."
            }
            else
            {
                log "$serviceKey registry key not found."
            }
        }
        foreach($key in $sccmKeys)
        {
            $keyPath = $ccmRegPath + "\" + $key
            if(Test-Path $keyPath)
            {
                log "Removing $keyPath registry key..."
                Remove-Item -Path $keyPath -Recurse -Force -ErrorAction SilentlyContinue
                log "Removed $keyPath registry key."
            }
            else
            {
                log "$keyPath registry key not found."
            }
        }
        # Remove CSP
        Remove-Item -Path $CSPPath -Recurse -Force -ErrorAction SilentlyContinue
        # Remove SCCM folders
        foreach($folder in $sccmFolders)
        {
            if(Test-Path $folder)
            {
                log "Removing $folder..."
                Remove-Item -Path $folder -Recurse -Force -ErrorAction SilentlyContinue
                log "Removed $folder."
            }
            else
            {
                log "$folder not found."
            }
        }
    }
    else
    {
        log "SCCM client not found."
    }
}


# Remove SCCM client if required
log "Checking for SCCM client..."
if($config.SCCM -eq $true)
{
    log "SCCM enabled.  Removing SCCM client..."
    try
    {
        removeSCCM
        log "SCCM client removed successfully."
    }
    catch
    {
        $message = $_.Exception.Message
        log "Failed to remove SCCM client. Error: $message"
        log "Exiting script."
        [System.Windows.Forms.MessageBox]::Show("Failed to remove SCCM client. Error :$message", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        Return
    }
}
else
{
    log "SCCM not enabled."
}

# Delete source tenant objects
log "Deleting source tenant objects..."
# intune delete
if($pc.intuneId)
{
    log "Deleting Intune object..."
    try
    {
        Invoke-RestMethod -Method DELETE -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($pc.intuneId)" -Headers $sourceHeaders
        log "Intune object deleted successfully."
    }
    catch
    {
        $message = $_.Exception.Message
        log "Failed to delete Intune object. Error: $message"
    }
}
else
{
    log "Intune object not found."
}

# autopilot delete
if($pc.autopilotId)
{
    log "Deleting Autopilot object..."
    try
    {
        Invoke-RestMethod -Method DELETE -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities/$($pc.autopilotId)" -Headers $sourceHeaders
        log "Autopilot object deleted successfully."
    }
    catch
    {
        $message = $_.Exception.Message
        log "Failed to delete Autopilot object. Error: $message"
    }
}
else
{
    log "Autopilot object not found."
}

# Install provisioning package
$ppkg = (Get-ChildItem -Path $config.localPath -Filter "*.ppkg" -Recurse).FullName
if($ppkg)
{
    log "Provisioning package found. Installing..."
    try
    {
        Install-ProvisioningPackage -PackagePath $ppkg -QuietInstall -Force
        log "Provisioning package installed."
    }
    catch
    {
        $message = $_.Exception.Message
        log "Failed to install provisioning package. Error: $message"
        log "Exiting script."
        [System.Windows.Forms.MessageBox]::Show("Failed to install provisioning package. Error: $message", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
}
else
{
    log "Provisioning package not found."
    [System.Windows.Forms.MessageBox]::Show("Provisioning package not found", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
}

# Set auto logon
[string]$autoLogonPath = "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
reg.exe add $autoLogonPath /v "AutoAdminLogon" /t REG_SZ /d 0 /f | Out-Host
reg.exe add $autoLogonPath /v "DefaultUserName" /t REG_SZ /d $migrateAdmin /f | Out-Host
reg.exe add $autoLogonPath /v "DefaultPassword" /t REG_SZ /d "@Password*123" | Out-Host
log "Successfully set auto logon to $migrateAdmin."

# Enable auto logon
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "AutoAdminLogon" -Value 1 -Verbose
log "Auto logon enabled."

# Disable password logon provider
reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\{60b78e88-ead8-445c-9cfd-0b87f74ea6cd}" /v "Disabled" /t REG_DWORD /d 1 /f | Out-Host
log "Password logon provider disabled."

# Disable DisplayLastUser
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DontDisplayLastUserName" -Value 1 -Verbose
log "DisplayLastUser disabled."

# Set lock screen caption
if($targetHeaders)
{
    $tenant = $config.targetTenant.tenantName
}
else
{
    $tenant = $config.sourceTenant.tenantName
}
reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v "legalnoticecaption" /t REG_SZ /d "Device Migration in Progress..." /f | Out-Host 
reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v "legalnoticetext" /t REG_SZ /d "Your PC is being migrated to the $($tenant) tenant and will automatically reboot in 30 seconds.  Please do not power off." /f | Out-Host
log "Lock screen caption set successfully."

# Disable user ESP
$SkipOOBE = get-childitem -path HKLM:\software\microsoft\enrollments\ -Recurse | Where-Object { $_.Property -match 'SkipUserStatusPage' }
if ($SkipOOBE) 
{
    $Converted = Convert-Path $SkipOOBE.PSPath
    New-ItemProperty -Path Registry::$Converted -Name SkipUserStatusPage  -Value 4294967295 -PropertyType DWORD -Force | Out-Null
}
else 
{
    log "SkipUserStatusPage not found."
}

# Stop transcript and restart
log "$($pc.hostname) will reboot in 30 seconds..."
Stop-Transcript
shutdown -r -t 30
