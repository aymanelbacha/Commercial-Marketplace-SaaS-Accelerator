# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License. See LICENSE file in the project root for license information.

#
# Powershell script to deploy the resources - Customer portal, Publisher portal and PostgreSQL on a private Linux VM
#

#.\Deploy.ps1 `
# -WebAppNamePrefix "amp_saas_accelerator_<unique>" `
# -Location "<region>" `
# -PublisherAdminUsers "<your@email.address>"

Param(  
   [string][Parameter(Mandatory)]$WebAppNamePrefix, # Prefix used for creating web applications
   [string][Parameter()]$ResourceGroupForDeployment, # Name of the resource group to deploy the resources
   [string][Parameter(Mandatory)]$Location, # Location of the resource group
   [string][Parameter(Mandatory)]$PublisherAdminUsers, # Provide a list of email addresses (as comma-separated-values) that should be granted access to the Publisher Portal
   [string][Parameter()]$TenantID, # The value should match the value provided for Active Directory TenantID in the Technical Configuration of the Transactable Offer in Partner Center
   [string][Parameter()]$AzureSubscriptionID, # Subscription where the resources be deployed
   [string][Parameter()]$ADApplicationID, # The value should match the value provided for Active Directory Application ID in the Technical Configuration of the Transactable Offer in Partner Center
   [string][Parameter()]$ADApplicationSecret, # Secret key of the AD Application
   [string][Parameter()]$ADApplicationIDAdmin, # Multi-Tenant Active Directory Application ID 
   [string][Parameter()]$ADMTApplicationIDPortal, #Multi-Tenant Active Directory Application ID for the Landing Portal
   [string][Parameter()]$IsAdminPortalMultiTenant, # If set to true, the Admin Portal will be configured as a multi-tenant application. This is by default set to false. 
   [string][Parameter()]$SQLDatabaseName, # Name of the database (Defaults to AMPSaaSDB)
   [string][Parameter()]$SQLServerName, # Name of the private PostgreSQL Linux VM (legacy param name retained)
   [string][Parameter()]$LogoURLpng,  # URL for Publisher .png logo
   [string][Parameter()]$LogoURLico,  # URL for Publisher .ico logo
   [string][Parameter()]$KeyVault, # Name of KeyVault
   [switch][Parameter()]$EnableKeyVaultPrivateEndpoint, # Optional hardened Key Vault private endpoint (off by default for reliability)
   [switch][Parameter()]$SkipBuild, # Skip dotnet publish if packages already built
   [switch][Parameter()]$SkipPostgresBootstrap, # Skip VM/network/postgres install when DB is already ready
   [switch][Parameter()]$Quiet, #if set, only show error / warning output from script commands
   [switch][Parameter()]$AcceptLicense # Skip the MIT license prompt (for non-interactive runs)
)

# Define the warning message
$message = @"
The SaaS Accelerator is offered under the MIT License as open source software and is not supported by Microsoft.

If you need help with the accelerator or would like to report defects or feature requests use the Issues feature on the GitHub repository at https://aka.ms/SaaSAccelerator

Do you agree? (Y/N)
"@

# Display the message in yellow
Write-Host $message -ForegroundColor Yellow

# Prompt the user for input
$response = if ($AcceptLicense) { 'Y' } else { Read-Host }

# Check the user's response
if ($response -ne 'Y' -and $response -ne 'y') {
    Write-Host "You did not agree. Exiting..." -ForegroundColor Red
    exit
}

# Proceed if the user agrees
Write-Host "Thank you for agreeing. Proceeding with the script..." -ForegroundColor Green

# Make sure to install Az Module before running this script
# Install-Module Az
# Install-Module -Name AzureAD

#region Select Tenant / Subscription for deployment

$currentContext = az account show | ConvertFrom-Json
$currentTenant = $currentContext.tenantId
$currentSubscription = $currentContext.id

#Get TenantID if not set as argument
if(!($TenantID)) {    
    Get-AzTenant | Format-Table
    if (!($TenantID = Read-Host "⌨  Type your TenantID or press Enter to accept your current one [$currentTenant]")) { $TenantID = $currentTenant }    
}
else {
    Write-Host "🔑 Tenant provided: $TenantID"
}

#Get Azure Subscription if not set as argument
if(!($AzureSubscriptionID)) {    
    Get-AzSubscription -TenantId $TenantID | Format-Table
    if (!($AzureSubscriptionID = Read-Host "⌨  Type your SubscriptionID or press Enter to accept your current one [$currentSubscription]")) { $AzureSubscriptionID = $currentSubscription }
}
else {
    Write-Host "🔑 Azure Subscription provided: $AzureSubscriptionID"
}

#Set the AZ Cli context
az account set -s $AzureSubscriptionID
Write-Host "🔑 Azure Subscription '$AzureSubscriptionID' selected."

#endregion



$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}
$startTime = Get-Date

$DeployScriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
. (Join-Path $DeployScriptRoot "scripts/Deploy-Helpers.ps1")

#region Set up Variables and Default Parameters

# Linux pwsh often does not set $env:TEMP; paths are resolved from the deployment folder.
$DeployTempDir = if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) {
    $env:TEMP
} elseif (-not [string]::IsNullOrWhiteSpace($env:TMPDIR)) {
    $env:TMPDIR
} else {
    [System.IO.Path]::GetTempPath().TrimEnd([char]'/', [char]'\')
}
$RepoRoot = Join-Path $DeployScriptRoot ".."
$PublishRoot = Join-Path $RepoRoot "Publish"
$AdminPublishDir = Join-Path $PublishRoot "AdminSite"
$PortalPublishDir = Join-Path $PublishRoot "CustomerSite"
$AdminZipPath = Join-Path $PublishRoot "AdminSite.zip"
$PortalZipPath = Join-Path $PublishRoot "CustomerSite.zip"
$MigrationScriptPath = Join-Path $DeployScriptRoot "script.sql"
$DevAppSettingsPath = Join-Path $RepoRoot "src/AdminSite/appsettings.Development.json"

if ($ResourceGroupForDeployment -eq "") {
    $ResourceGroupForDeployment = $WebAppNamePrefix 
}
if ($SQLServerName -eq "") {
    $SQLServerName = $WebAppNamePrefix + "-pgvm"
}
if ($SQLDatabaseName -eq "") {
    $SQLDatabaseName = $WebAppNamePrefix +"AMPSaaSDB"
}

if($KeyVault -eq "")
{
# User did not define KeyVault, so we will create one. 
# We need to check if the KeyVault already exists or purge before going forward

   $KeyVault=$WebAppNamePrefix+"-kv"

   # Check if the KeyVault exists under resource group
   $ErrorActionPreference = 'SilentlyContinue'
   $kv_check = az keyvault show -n $KeyVault -g $ResourceGroupForDeployment 2>$null
   if ($LASTEXITCODE -ne 0) { $kv_check = $null }
   $ErrorActionPreference = 'Stop'

   # If KeyVault does not exist under resource group, then we need to check if it deleted KeyVault
   if($kv_check -eq $null)
   {
	#region Check If KeyVault Exists
		$kv_check = az keyvault check-name --name $KeyVault | ConvertFrom-Json

		if ($kv_check.nameAvailable -eq $false)
		{
			Write-Host ""
			Write-Host "🛑  KeyVault name "  -NoNewline -ForegroundColor Red
			Write-Host "$KeyVault"  -NoNewline -ForegroundColor Red -BackgroundColor Yellow
			Write-Host " already exists." -ForegroundColor Red
			Write-Host "   To Purge KeyVault please use the following doc:"
			Write-Host "   https://learn.microsoft.com/en-us/cli/azure/keyvault?view=azure-cli-latest#az-keyvault-purge."
			Write-Host "   You could use new KeyVault name by using parameter" -NoNewline 
			Write-Host " -KeyVault"  -ForegroundColor Green
			exit 1
		}
	#endregion
	}

}

$SaaSApiConfiguration_CodeHash = try { git -C $RepoRoot log --format='%H' -1 2>$null } catch { $null }
if ([string]::IsNullOrWhiteSpace($SaaSApiConfiguration_CodeHash)) {
    $SaaSApiConfiguration_CodeHash = "unknown"
}
$azCliOutput = if($Quiet){'none'} else {'json'}

#endregion

#region Validate Parameters

if($WebAppNamePrefix.Length -gt 21) {
    Throw "🛑 Web name prefix must be less than 21 characters."
    exit 1
}

if(!($KeyVault -match "^[a-zA-Z][a-z0-9-]+$")) {
    Throw "🛑 KeyVault name only allows alphanumeric and hyphens, but cannot start with a number or special character."
    exit 1
}

if ($ADApplicationID -and -not $ADApplicationSecret) {
    Throw "🛑 ADApplicationSecret is required when ADApplicationID is provided."
    exit 1
}


#endregion 

#region pre-checks

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Throw "🛑 Azure CLI (az) is not installed or not on PATH."
}

$dotnetversion = dotnet --version
if(!$dotnetversion.StartsWith('8.')) {
    Throw "🛑 Dotnet 8 not installed. Install dotnet 8 SDK and re-run the script."
}

Ensure-DotNetEfTool
Test-SolutionBuild -RepoRoot $RepoRoot

#endregion


Write-Host "Starting SaaS Accelerator Deployment..."


#region Check If PostgreSQL VM Exists
$PostgresVmExists = $false
$ErrorActionPreference = 'SilentlyContinue'
$vm_exists = az vm show --name $SQLServerName --resource-group $ResourceGroupForDeployment 2>$null
if ($LASTEXITCODE -ne 0) { $vm_exists = $null }
$ErrorActionPreference = 'Stop'
if ($vm_exists) {
    Write-Host "      PostgreSQL VM '$SQLServerName' already exists; will reuse it." -ForegroundColor Yellow
    $PostgresVmExists = $true
}
#endregion

#region Dowloading assets if provided

# Download Publisher's PNG logo
if($LogoURLpng) { 
    Write-Host "📷 Logo image provided"
	Write-Host "   🔵 Downloading Logo image file"
    Invoke-WebRequest -Uri $LogoURLpng -OutFile (Join-Path $RepoRoot "src/CustomerSite/wwwroot/contoso-sales.png")
    Invoke-WebRequest -Uri $LogoURLpng -OutFile (Join-Path $RepoRoot "src/AdminSite/wwwroot/contoso-sales.png")
    Write-Host "   🔵 Logo image downloaded"
}

# Download Publisher's FAVICON logo
if($LogoURLico) { 
    Write-Host "📷 Logo icon provided"
	Write-Host "   🔵 Downloading Logo icon file"
    Invoke-WebRequest -Uri $LogoURLico -OutFile (Join-Path $RepoRoot "src/CustomerSite/wwwroot/favicon.ico")
    Invoke-WebRequest -Uri $LogoURLico -OutFile (Join-Path $RepoRoot "src/AdminSite/wwwroot/favicon.ico")
    Write-Host "   🔵 Logo icon downloaded"
}

#endregion
 
#region Create AAD App Registrations

#Record the current ADApps to reduce deployment instructions at the end
$ISLoginAppProvided = ($ADApplicationIDAdmin -ne "" -or $ADMTApplicationIDPortal -ne "")


if($ISLoginAppProvided){
	Write-Host "🔑 Multi-Tenant App Registrations provided."
	Write-Host "   ➡️ Admin Portal App Registration ID:" $ADApplicationIDAdmin
	Write-Host "   ➡️ Landing Page App Registration ID:" $ADMTApplicationIDPortal
}
else {
	Write-Host "🔑 Multi-Tenant App Registrations not provided."
}



if($IsAdminPortalMultiTenant -eq "true"){
	Write-Host "🔑 Admin Portal App Registration set as Multi-Tenant."
	$IsAdminPortalMultiTenant = $true
}
else {
	Write-Host "🔑 Admin Portal App Registration set as Single-Tenant."
	$IsAdminPortalMultiTenant = $false
}






#Create App Registration for authenticating calls to the Marketplace API
if (!($ADApplicationID)) {   
    Write-Host "🔑 Creating Fulfilment API App Registration"
    try {   
        $fulfillmentDisplayName = "$WebAppNamePrefix-FulfillmentAppReg"
        $ErrorActionPreference = 'SilentlyContinue'
        $existingApps = @(az ad app list --display-name $fulfillmentDisplayName --query "[?displayName=='$fulfillmentDisplayName']" | ConvertFrom-Json)
        $ErrorActionPreference = 'Stop'

        if ($existingApps.Count -gt 0) {
            $ADApplication = $existingApps[0]
            Write-Host "   🔵 Reusing existing FulfilmentAPI App Registration."
        } else {
            $ADApplication = az ad app create --only-show-errors --sign-in-audience AzureADMYOrg --display-name $fulfillmentDisplayName | ConvertFrom-Json
        }

		$ADObjectID = $ADApplication.id
        $ADApplicationID = $ADApplication.appId
        sleep 5 #this is to give time to AAD to register

        $ErrorActionPreference = 'SilentlyContinue'
        az ad sp show --id $ADApplicationID 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            az ad sp create --id $ADApplicationID 2>$null
            if ($LASTEXITCODE -ne 0) { throw "Failed to create service principal for app $ADApplicationID" }
        }
        $ErrorActionPreference = 'Stop'

        $ADApplicationSecret = az ad app credential reset --id $ADObjectID --append --display-name 'SaaSAPI' --years 2 --query password --only-show-errors --output tsv
				
        Write-Host "   🔵 FulfilmentAPI App Registration created."
		Write-Host "      ➡️ Application ID:" $ADApplicationID
    }
    catch [System.Net.WebException],[System.IO.IOException] {
        Write-Host "🚨🚨   $PSItem.Exception"
        exit 1
    }
}

#Create Multi-Tenant App Registration for Admin Portal User Login
if (!($ADApplicationIDAdmin)) {  
    Write-Host "🔑 Creating Admin Portal SSO App Registration"
    try {
	
		$appCreateRequestBodyJson = @"
{
	"displayName" : "$WebAppNamePrefix-AdminPortalAppReg",
	"api": 
	{
		"requestedAccessTokenVersion" : 2
	},
	"signInAudience" : "AzureADMyOrg",
	"web":
	{ 
		"redirectUris": 
		[
			
			"https://$WebAppNamePrefix-admin.azurewebsites.net",
			"https://$WebAppNamePrefix-admin.azurewebsites.net/",
			"https://$WebAppNamePrefix-admin.azurewebsites.net/Home/Index",
			"https://$WebAppNamePrefix-admin.azurewebsites.net/Home/Index/"
		],
		"logoutUrl": "https://$WebAppNamePrefix-admin.azurewebsites.net/logout",
		"implicitGrantSettings": 
			{ "enableIdTokenIssuance" : true }
	},
	"requiredResourceAccess":
	[{
		"resourceAppId": "00000003-0000-0000-c000-000000000000",
		"resourceAccess":
			[{ 
				"id": "e1fe6dd8-ba31-4d61-89e7-88639da4683d",
				"type": "Scope" 
			}]
	}]
}
"@	
		if ($PsVersionTable.Platform -ne 'Unix') {
			#On Windows, we need to escape quotes and remove new lines before sending the payload to az rest. 
			# See: https://github.com/Azure/azure-cli/blob/dev/doc/quoting-issues-with-powershell.md#double-quotes--are-lost
			$appCreateRequestBodyJson = $appCreateRequestBodyJson.replace('"','\"').replace("`r`n","")
		}

		$adminPortalAppReg = $(az rest --method POST --headers "Content-Type=application/json" --uri https://graph.microsoft.com/v1.0/applications --body $appCreateRequestBodyJson  ) | ConvertFrom-Json
	
		$ADApplicationIDAdmin = $adminPortalAppReg.appId
		$ADMTObjectIDAdmin = $adminPortalAppReg.id
	
        Write-Host "   🔵 Admin Portal SSO App Registration created."
		Write-Host "      ➡️ Application Id: $ADApplicationIDAdmin"


		# Download Publisher's AppRegistration logo
        if($LogoURLpng) { 
			Write-Host "   🔵 Logo image provided. Setting the Application branding logo"
			Write-Host "      ➡️ Setting the Application branding logo"
			$token=(az account get-access-token --resource "https://graph.microsoft.com" --query accessToken --output tsv)
			$logoWeb = Invoke-WebRequest $LogoURLpng
			$logoContentType = $logoWeb.Headers["Content-Type"]
			$logoContent = $logoWeb.Content
			
			$uploaded = Invoke-WebRequest `
			  -Uri "https://graph.microsoft.com/v1.0/applications/$ADMTObjectIDAdmin/logo" `
			  -Method "PUT" `
			  -Header @{"Authorization"="Bearer $token";"Content-Type"="$logoContentType";} `
			  -Body $logoContent
		    
			Write-Host "      ➡️ Application branding logo set."
        }

    }
    catch [System.Net.WebException],[System.IO.IOException] {
        Write-Host "🚨🚨   $PSItem.Exception"
        exit 1
    }
}

#Create Multi-Tenant App Registration for Landing Page User Login
if (!($ADMTApplicationIDPortal)) {  
    Write-Host "🔑 Creating Landing Page SSO App Registration"
    try {
	
		$appCreateRequestBodyJson = @"
{
	"displayName" : "$WebAppNamePrefix-LandingpageAppReg",
	"api": 
	{
		"requestedAccessTokenVersion" : 2
	},
	"signInAudience" : "AzureADandPersonalMicrosoftAccount",
	"web":
	{ 
		"redirectUris": 
		[
			"https://$WebAppNamePrefix-portal.azurewebsites.net",
			"https://$WebAppNamePrefix-portal.azurewebsites.net/",
			"https://$WebAppNamePrefix-portal.azurewebsites.net/Home/Index",
			"https://$WebAppNamePrefix-portal.azurewebsites.net/Home/Index/"
			
		],
		"logoutUrl": "https://$WebAppNamePrefix-portal.azurewebsites.net/logout",
		"implicitGrantSettings": 
			{ "enableIdTokenIssuance" : true }
	},
	"requiredResourceAccess":
	[{
		"resourceAppId": "00000003-0000-0000-c000-000000000000",
		"resourceAccess":
			[{ 
				"id": "e1fe6dd8-ba31-4d61-89e7-88639da4683d",
				"type": "Scope" 
			}]
	}]
}
"@	
		if ($PsVersionTable.Platform -ne 'Unix') {
			#On Windows, we need to escape quotes and remove new lines before sending the payload to az rest. 
			# See: https://github.com/Azure/azure-cli/blob/dev/doc/quoting-issues-with-powershell.md#double-quotes--are-lost
			$appCreateRequestBodyJson = $appCreateRequestBodyJson.replace('"','\"').replace("`r`n","")
		}

		$landingpageLoginAppReg = $(az rest --method POST --headers "Content-Type=application/json" --uri https://graph.microsoft.com/v1.0/applications --body $appCreateRequestBodyJson  ) | ConvertFrom-Json
	
		$ADMTApplicationIDPortal = $landingpageLoginAppReg.appId
		$ADMTObjectIDPortal = $landingpageLoginAppReg.id
	
        Write-Host "   🔵 Landing Page SSO App Registration created."
		Write-Host "      ➡️ Application Id: $ADMTApplicationIDPortal"
	
		# Download Publisher's AppRegistration logo
        if($LogoURLpng) { 
			Write-Host "   🔵 Logo image provided. Setting the Application branding logo"
			Write-Host "      ➡️ Setting the Application branding logo"
			$token=(az account get-access-token --resource "https://graph.microsoft.com" --query accessToken --output tsv)
			$logoWeb = Invoke-WebRequest $LogoURLpng
			$logoContentType = $logoWeb.Headers["Content-Type"]
			$logoContent = $logoWeb.Content
			
			$uploaded = Invoke-WebRequest `
			  -Uri "https://graph.microsoft.com/v1.0/applications/$ADMTObjectIDPortal/logo" `
			  -Method "PUT" `
			  -Header @{"Authorization"="Bearer $token";"Content-Type"="$logoContentType";} `
			  -Body $logoContent
		    
			Write-Host "      ➡️ Application branding logo set."
        }

    }
    catch [System.Net.WebException],[System.IO.IOException] {
        Write-Host "🚨🚨   $PSItem.Exception"
        exit 1
    }
}

#endregion

#region Prepare Code Packages
Write-host "📜 Prepare publish files for the application"
if (-not $SkipBuild) {
    Build-PublishPackages `
        -RepoRoot $RepoRoot `
        -PublishRoot $PublishRoot `
        -AdminPublishDir $AdminPublishDir `
        -PortalPublishDir $PortalPublishDir `
        -AdminZipPath $AdminZipPath `
        -PortalZipPath $PortalZipPath
} elseif (-not (Test-Path $AdminZipPath) -or -not (Test-Path $PortalZipPath)) {
    throw "SkipBuild was set but publish packages were not found. Remove -SkipBuild or build Publish/*.zip first."
}
#endregion

#region Deploy Azure Resources Infrastructure
Write-host "☁ Deploy Azure Resources"

#Set-up resource name variables
$WebAppNameService=$WebAppNamePrefix+"-asp"
$WebAppNameAdmin=$WebAppNamePrefix+"-admin"
$WebAppNamePortal=$WebAppNamePrefix+"-portal"
$VnetName=$WebAppNamePrefix+"-vnet"
$privateKvEndpointName=$WebAppNamePrefix+"-kv-pe"
$privateKvDnsZoneName="privatelink.vaultcore.windows.net"
$privateKvlink =$WebAppNamePrefix+"-kv-link"
$WebSubnetName="web"
$SqlSubnetName="sql"
$KvSubnetName="kv"
$DefaultSubnetName="default"
$PostgresNsgName=$WebAppNamePrefix+"-pg-nsg"
$PostgresAdminUser="saasadmin"
$DeployStatePath = Join-Path $DeployTempDir "$WebAppNamePrefix-deploy-state.json"
if (Test-Path $DeployStatePath) {
    $deployState = Get-Content -Path $DeployStatePath -Raw | ConvertFrom-Json
    $PostgresAdminPassword = $deployState.PostgresAdminPassword
    Write-Host "      Reusing PostgreSQL credentials from prior deploy run." -ForegroundColor Yellow
} elseif ($env:SAAS_DEPLOY_POSTGRES_PASSWORD) {
    $PostgresAdminPassword = $env:SAAS_DEPLOY_POSTGRES_PASSWORD
} else {
    $PostgresAdminPassword = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object {[char]$_})
}
@{ PostgresAdminPassword = $PostgresAdminPassword; WebAppNamePrefix = $WebAppNamePrefix } | ConvertTo-Json | Set-Content -Path $DeployStatePath -Encoding UTF8
$VnetCidr="10.0.0.0/20"
$WebSubnetCidr="10.0.1.0/24"

#keep the space at the end of the string - bug in az cli running on windows powershell truncates last char https://github.com/Azure/azure-cli/issues/10066
$ADApplicationSecretKeyVault="@Microsoft.KeyVault(VaultName=$KeyVault;SecretName=ADApplicationSecret) "
$DefaultConnectionKeyVault="@Microsoft.KeyVault(VaultName=$KeyVault;SecretName=DefaultConnection) "

Write-host "   🔵 Resource Group"
Write-host "      ➡️ Create Resource Group"
$ErrorActionPreference = 'SilentlyContinue'
$existingRgJson = az group show --name $ResourceGroupForDeployment 2>$null
$ErrorActionPreference = 'Stop'
if ($LASTEXITCODE -eq 0 -and $existingRgJson) {
    $existingRg = $existingRgJson | ConvertFrom-Json
    $requestedLocation = ($Location -replace '\s', '').ToLower()
    if ($existingRg.location -ne $requestedLocation) {
        Write-Host "      Resource group '$ResourceGroupForDeployment' already exists in '$($existingRg.location)'; using that location instead of '$Location'." -ForegroundColor Yellow
    }
    $Location = $existingRg.location
} else {
    az group create --location $Location --name $ResourceGroupForDeployment --output $azCliOutput
    if ($LASTEXITCODE -ne 0) { throw "Failed to create resource group $ResourceGroupForDeployment in $Location" }
}

Write-host "      ➡️ Create VNET and Subnet"
$ErrorActionPreference = 'SilentlyContinue'
$vnetExists = az network vnet show --resource-group $ResourceGroupForDeployment --name $VnetName 2>$null
$ErrorActionPreference = 'Stop'
if (-not $vnetExists) {
    az network vnet create --resource-group $ResourceGroupForDeployment --name $VnetName --address-prefixes "10.0.0.0/20" --output $azCliOutput
    if ($LASTEXITCODE -ne 0) { throw "Failed to create virtual network $VnetName" }
}
function Ensure-VnetSubnet {
    param(
        [string]$ResourceGroup,
        [string]$Vnet,
        [string]$SubnetName,
        [string[]]$CreateArgs
    )
    $ErrorActionPreference = 'SilentlyContinue'
    $subnetExists = az network vnet subnet show --resource-group $ResourceGroup --vnet-name $Vnet --name $SubnetName 2>$null
    $ErrorActionPreference = 'Stop'
    if (-not $subnetExists) {
        az network vnet subnet create @CreateArgs --output $azCliOutput
        if ($LASTEXITCODE -ne 0) { throw "Failed to create subnet $SubnetName" }
    }
}
Ensure-VnetSubnet -ResourceGroup $ResourceGroupForDeployment -Vnet $VnetName -SubnetName $DefaultSubnetName -CreateArgs @('--resource-group', $ResourceGroupForDeployment, '--vnet-name', $VnetName, '-n', $DefaultSubnetName, '--address-prefixes', '10.0.0.0/24')
Ensure-VnetSubnet -ResourceGroup $ResourceGroupForDeployment -Vnet $VnetName -SubnetName $WebSubnetName -CreateArgs @('--resource-group', $ResourceGroupForDeployment, '--vnet-name', $VnetName, '-n', $WebSubnetName, '--address-prefixes', $WebSubnetCidr, '--service-endpoints', 'Microsoft.KeyVault', '--delegations', 'Microsoft.Web/serverfarms')
Ensure-VnetSubnet -ResourceGroup $ResourceGroupForDeployment -Vnet $VnetName -SubnetName $SqlSubnetName -CreateArgs @('--resource-group', $ResourceGroupForDeployment, '--vnet-name', $VnetName, '-n', $SqlSubnetName, '--address-prefixes', '10.0.2.0/24')
Ensure-VnetSubnet -ResourceGroup $ResourceGroupForDeployment -Vnet $VnetName -SubnetName $KvSubnetName -CreateArgs @('--resource-group', $ResourceGroupForDeployment, '--vnet-name', $VnetName, '-n', $KvSubnetName, '--address-prefixes', '10.0.3.0/24')

if (-not $SkipPostgresBootstrap) {
Write-host "      ➡️ Create PostgreSQL VM network security group (private-only)"
$ErrorActionPreference = 'SilentlyContinue'
$nsgExists = az network nsg show --resource-group $ResourceGroupForDeployment --name $PostgresNsgName 2>$null
$ErrorActionPreference = 'Stop'
if (-not $nsgExists) {
    az network nsg create --resource-group $ResourceGroupForDeployment --name $PostgresNsgName --location $Location --output $azCliOutput
    if ($LASTEXITCODE -ne 0) { throw "Failed to create NSG $PostgresNsgName" }
    az network nsg rule create --resource-group $ResourceGroupForDeployment --nsg-name $PostgresNsgName -n AllowPostgresFromWeb --priority 100 --direction Inbound --access Allow --protocol Tcp --source-address-prefixes $WebSubnetCidr --source-port-ranges "*" --destination-address-prefixes "*" --destination-port-ranges 5432 --output $azCliOutput
    az network nsg rule create --resource-group $ResourceGroupForDeployment --nsg-name $PostgresNsgName -n AllowOutboundHttps --priority 110 --direction Outbound --access Allow --protocol Tcp --source-address-prefixes "*" --source-port-ranges "*" --destination-address-prefixes "Internet" --destination-port-ranges 443 --output $azCliOutput
    az network nsg rule create --resource-group $ResourceGroupForDeployment --nsg-name $PostgresNsgName -n AllowOutboundHttp --priority 120 --direction Outbound --access Allow --protocol Tcp --source-address-prefixes "*" --source-port-ranges "*" --destination-address-prefixes "Internet" --destination-port-ranges 80 --output $azCliOutput
}
az network vnet subnet update --resource-group $ResourceGroupForDeployment --vnet-name $VnetName --name $SqlSubnetName --network-security-group $PostgresNsgName --output $azCliOutput

Write-host "      ➡️ Create private PostgreSQL 16 Linux VM in sql subnet"
if (-not $PostgresVmExists) {
    $orphanedNic = "${SQLServerName}VMNic"
    $ErrorActionPreference = 'SilentlyContinue'
    az network nic show --resource-group $ResourceGroupForDeployment --name $orphanedNic 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "      Removing orphaned NIC $orphanedNic from a prior failed deploy..."
        az network nic delete --resource-group $ResourceGroupForDeployment --name $orphanedNic --output none
    }
    $ErrorActionPreference = 'Stop'

    $ErrorActionPreference = 'Continue'
    az vm create `
        --resource-group $ResourceGroupForDeployment `
        --name $SQLServerName `
        --location $Location `
        --image Ubuntu2204 `
        --size Standard_B2s `
        --admin-username azureuser `
        --generate-ssh-keys `
        --public-ip-address '""' `
        --vnet-name $VnetName `
        --subnet $SqlSubnetName `
        --nsg $PostgresNsgName `
        --output $azCliOutput
    if ($LASTEXITCODE -ne 0) { throw "Failed to create PostgreSQL VM '$SQLServerName'." }
    $ErrorActionPreference = 'Stop'
} else {
    Write-Host "      Skipping PostgreSQL VM create (already exists)."
}

Write-host "      ➡️ Bootstrap PostgreSQL on VM"
& (Join-Path $DeployScriptRoot "postgres/Ensure-PostgresReady.ps1") `
    -ResourceGroup $ResourceGroupForDeployment `
    -VmName $SQLServerName `
    -DeployScriptRoot (Join-Path $DeployScriptRoot "postgres") `
    -DatabaseName $SQLDatabaseName `
    -DatabaseUser $PostgresAdminUser `
    -DatabasePassword $PostgresAdminPassword `
    -VnetCidr $VnetCidr
} else {
    Write-Host "      Skipping PostgreSQL VM bootstrap (-SkipPostgresBootstrap). Using existing VM '$SQLServerName'."
    $ErrorActionPreference = 'SilentlyContinue'
    $vmCheck = az vm show --name $SQLServerName --resource-group $ResourceGroupForDeployment 2>$null
    $ErrorActionPreference = 'Stop'
    if (-not $vmCheck) { throw "PostgreSQL VM '$SQLServerName' not found. Remove -SkipPostgresBootstrap or create the VM first." }
}

$PostgresPrivateIp = az vm list-ip-addresses --resource-group $ResourceGroupForDeployment --name $SQLServerName --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv
if ([string]::IsNullOrWhiteSpace($PostgresPrivateIp)) {
    throw "Could not resolve private IP for PostgreSQL VM '$SQLServerName'."
}
Write-host "      ➡️ PostgreSQL private endpoint: ${PostgresPrivateIp}:5432"

$Connection="Host=$PostgresPrivateIp;Port=5432;Database=$SQLDatabaseName;Username=$PostgresAdminUser;Password=$PostgresAdminPassword;SSL Mode=Prefer;Trust Server Certificate=true"

Write-host "   🔵 KeyVault"
Write-host "      ➡️ Create KeyVault"
$ErrorActionPreference = 'SilentlyContinue'
$kvExists = az keyvault show --name $KeyVault --resource-group $ResourceGroupForDeployment 2>$null
$ErrorActionPreference = 'Stop'
if (-not $kvExists) {
    az keyvault create --name $KeyVault --resource-group $ResourceGroupForDeployment --enable-rbac-authorization false --output $azCliOutput
    if ($LASTEXITCODE -ne 0) { throw "Failed to create Key Vault $KeyVault" }
} else {
    Write-Host "      Key Vault '$KeyVault' already exists; reusing it." -ForegroundColor Yellow
}
Write-host "      ➡️ Add Secrets"
Set-KeyVaultSecrets -KeyVault $KeyVault -ResourceGroup $ResourceGroupForDeployment -AzCliOutput $azCliOutput -Secrets @{
    ADApplicationSecret = $ADApplicationSecret
    DefaultConnection = $Connection
    PostgresAdminPassword = $PostgresAdminPassword
}
Write-host "      ➡️ Update Firewall"
az keyvault update --name $KeyVault --resource-group $ResourceGroupForDeployment --default-action Deny --output $azCliOutput
az keyvault network-rule add --name $KeyVault --resource-group $ResourceGroupForDeployment --vnet-name $VnetName --subnet $WebSubnetName --output $azCliOutput

Write-host "   🔵 App Service Plan"
Write-host "      ➡️ Create App Service Plan"
$ErrorActionPreference = 'SilentlyContinue'
$aspExists = az appservice plan show -g $ResourceGroupForDeployment -n $WebAppNameService 2>$null
$ErrorActionPreference = 'Stop'
if (-not $aspExists) {
    $ErrorActionPreference = 'Continue'
    az appservice plan create -g $ResourceGroupForDeployment -n $WebAppNameService --sku B1 --output $azCliOutput
    if ($LASTEXITCODE -ne 0) { throw "Failed to create App Service Plan $WebAppNameService" }
    $ErrorActionPreference = 'Stop'
} else {
    Write-Host "      App Service Plan '$WebAppNameService' already exists; reusing it." -ForegroundColor Yellow
}

Write-host "   🔵 Admin Portal WebApp"
Write-host "      ➡️ Create Web App"
$ErrorActionPreference = 'SilentlyContinue'
$adminAppExists = az webapp show -g $ResourceGroupForDeployment -n $WebAppNameAdmin 2>$null
$ErrorActionPreference = 'Stop'
if (-not $adminAppExists) {
    $ErrorActionPreference = 'Continue'
    az webapp create -g $ResourceGroupForDeployment -p $WebAppNameService -n $WebAppNameAdmin  --runtime dotnet:8 --output $azCliOutput
    if ($LASTEXITCODE -ne 0) { throw "Failed to create web app $WebAppNameAdmin" }
    $ErrorActionPreference = 'Stop'
} else {
    Write-Host "      Web app '$WebAppNameAdmin' already exists; reusing it." -ForegroundColor Yellow
}
Write-host "      ➡️ Assign Identity"
$WebAppNameAdminId = az webapp identity assign -g $ResourceGroupForDeployment  -n $WebAppNameAdmin --identities [system] --query principalId -o tsv
Write-host "      ➡️ Setup access to KeyVault"
az keyvault set-policy --name $KeyVault  --object-id $WebAppNameAdminId --secret-permissions get list --key-permissions get list --resource-group $ResourceGroupForDeployment --output $azCliOutput
Write-host "      ➡️ Set Configuration"
az webapp config appsettings set -g $ResourceGroupForDeployment  -n $WebAppNameAdmin --output $azCliOutput --settings KnownUsers=$PublisherAdminUsers SaaSApiConfiguration__AdAuthenticationEndPoint=https://login.microsoftonline.com SaaSApiConfiguration__ClientId=$ADApplicationID SaaSApiConfiguration__FulFillmentAPIBaseURL=https://marketplaceapi.microsoft.com/api SaaSApiConfiguration__FulFillmentAPIVersion=2018-08-31 SaaSApiConfiguration__GrantType=client_credentials SaaSApiConfiguration__MTClientId=$ADApplicationIDAdmin SaaSApiConfiguration__IsAdminPortalMultiTenant=$IsAdminPortalMultiTenant SaaSApiConfiguration__Resource=20e940b3-4c77-4b0b-9a53-9e16a1b010a7 SaaSApiConfiguration__TenantId=$TenantID SaaSApiConfiguration__SignedOutRedirectUri=https://$WebAppNamePrefix-admin.azurewebsites.net/Home/Index/ SaaSApiConfiguration_CodeHash=$SaaSApiConfiguration_CodeHash
az webapp config set -g $ResourceGroupForDeployment -n $WebAppNameAdmin --always-on true  --output $azCliOutput

Write-host "   🔵 Customer Portal WebApp"
Write-host "      ➡️ Create Web App"
$ErrorActionPreference = 'SilentlyContinue'
$portalAppExists = az webapp show -g $ResourceGroupForDeployment -n $WebAppNamePortal 2>$null
$ErrorActionPreference = 'Stop'
if (-not $portalAppExists) {
    $ErrorActionPreference = 'Continue'
    az webapp create -g $ResourceGroupForDeployment -p $WebAppNameService -n $WebAppNamePortal --runtime dotnet:8 --output $azCliOutput
    if ($LASTEXITCODE -ne 0) { throw "Failed to create web app $WebAppNamePortal" }
    $ErrorActionPreference = 'Stop'
} else {
    Write-Host "      Web app '$WebAppNamePortal' already exists; reusing it." -ForegroundColor Yellow
}
Write-host "      ➡️ Assign Identity"
$WebAppNamePortalId= az webapp identity assign -g $ResourceGroupForDeployment  -n $WebAppNamePortal --identities [system] --query principalId -o tsv 
Write-host "      ➡️ Setup access to KeyVault"
az keyvault set-policy --name $KeyVault  --object-id $WebAppNamePortalId --secret-permissions get list --key-permissions get list --resource-group $ResourceGroupForDeployment --output $azCliOutput
Write-host "      ➡️ Set Configuration"
az webapp config appsettings set -g $ResourceGroupForDeployment  -n $WebAppNamePortal --output $azCliOutput --settings SaaSApiConfiguration__AdAuthenticationEndPoint=https://login.microsoftonline.com SaaSApiConfiguration__ClientId=$ADApplicationID SaaSApiConfiguration__FulFillmentAPIBaseURL=https://marketplaceapi.microsoft.com/api SaaSApiConfiguration__FulFillmentAPIVersion=2018-08-31 SaaSApiConfiguration__GrantType=client_credentials SaaSApiConfiguration__MTClientId=$ADMTApplicationIDPortal SaaSApiConfiguration__Resource=20e940b3-4c77-4b0b-9a53-9e16a1b010a7 SaaSApiConfiguration__TenantId=$TenantID SaaSApiConfiguration__SignedOutRedirectUri=https://$WebAppNamePrefix-portal.azurewebsites.net/Home/Index/ SaaSApiConfiguration_CodeHash=$SaaSApiConfiguration_CodeHash
az webapp config set -g $ResourceGroupForDeployment -n $WebAppNamePortal --always-on true --output $azCliOutput

Write-host "   🔵 Integrate WebApps with VNet (required for Key Vault + private PostgreSQL)"
Add-WebAppVnetIntegration -ResourceGroup $ResourceGroupForDeployment -WebAppName $WebAppNamePortal -VnetName $VnetName -SubnetName $WebSubnetName -AzCliOutput $azCliOutput
Add-WebAppVnetIntegration -ResourceGroup $ResourceGroupForDeployment -WebAppName $WebAppNameAdmin -VnetName $VnetName -SubnetName $WebSubnetName -AzCliOutput $azCliOutput
Configure-WebAppDatabaseSettings -ResourceGroup $ResourceGroupForDeployment -WebAppName $WebAppNamePortal -ConnectionString $Connection -ClientSecret $ADApplicationSecret -AzCliOutput $azCliOutput
Configure-WebAppDatabaseSettings -ResourceGroup $ResourceGroupForDeployment -WebAppName $WebAppNameAdmin -ConnectionString $Connection -ClientSecret $ADApplicationSecret -AzCliOutput $azCliOutput

#endregion

#region Deploy Code
Write-host "📜 Deploy Code"

Write-host "   🔵 Deploy Database"
Write-host "      ➡️ Generate PostgreSQL schema/data script"
$ConnectionString=$Connection
Set-Content -Path $DevAppSettingsPath -value "{`"ConnectionStrings`": {`"DefaultConnection`":`"$ConnectionString`"}}"
dotnet ef migrations script --output $MigrationScriptPath --idempotent --context SaaSKitContext --project (Join-Path $RepoRoot "src/DataAccess/DataAccess.csproj") --startup-project (Join-Path $RepoRoot "src/AdminSite/AdminSite.csproj")

Write-host "      ➡️ Apply EF migrations history compatibility script"
Invoke-PostgresCompatibilityMigration `
    -DeployScriptRoot $DeployScriptRoot `
    -DeployTempDir $DeployTempDir `
    -ResourceGroup $ResourceGroupForDeployment `
    -VmName $SQLServerName `
    -DatabaseName $SQLDatabaseName `
    -DatabaseUser $PostgresAdminUser `
    -DatabasePassword $PostgresAdminPassword

Write-host "      ➡️ Execute PostgreSQL schema/data script on private VM"
& (Join-Path $DeployScriptRoot "postgres/Invoke-PostgresMigration.ps1") `
    -ResourceGroup $ResourceGroupForDeployment `
    -VmName $SQLServerName `
    -DatabaseName $SQLDatabaseName `
    -DatabaseUser $PostgresAdminUser `
    -DatabasePassword $PostgresAdminPassword `
    -ScriptPath $MigrationScriptPath

Write-host "   🔵 Deploy Code to Admin Portal"
if (-not (Test-Path $AdminZipPath)) {
    throw "Admin publish package not found: $AdminZipPath"
}
$ErrorActionPreference = 'Continue'
az webapp deploy --resource-group $ResourceGroupForDeployment --name $WebAppNameAdmin --src-path $AdminZipPath --type zip --output $azCliOutput
if ($LASTEXITCODE -ne 0) { throw "Failed to deploy Admin portal package to $WebAppNameAdmin" }

Write-host "   🔵 Deploy Code to Customer Portal"
if (-not (Test-Path $PortalZipPath)) {
    throw "Customer publish package not found: $PortalZipPath"
}
az webapp deploy --resource-group $ResourceGroupForDeployment --name $WebAppNamePortal --src-path $PortalZipPath --type zip --output $azCliOutput
if ($LASTEXITCODE -ne 0) { throw "Failed to deploy Customer portal package to $WebAppNamePortal" }
$ErrorActionPreference = 'Stop'

Write-host "   🔵 Restart WebApps"
az webapp restart -g $ResourceGroupForDeployment -n $WebAppNameAdmin --output $azCliOutput
az webapp restart -g $ResourceGroupForDeployment -n $WebAppNamePortal --output $azCliOutput

Write-host "   🔵 Verify deployed applications"
Test-WebAppDeploymentHealth -WebAppName $WebAppNamePortal
Test-WebAppDeploymentHealth -WebAppName $WebAppNameAdmin -HealthPath "/Account/SignIn"

Write-host "   🔵 Clean up"
Remove-Item -Path $DevAppSettingsPath -ErrorAction SilentlyContinue
Remove-Item -Path $MigrationScriptPath -ErrorAction SilentlyContinue
#Remove-Item -Path $PublishRoot -recurse -Force

#endregion

#region Create KV Private Endpoints
if ($EnableKeyVaultPrivateEndpoint) {
    Install-KeyVaultPrivateEndpoint `
        -ResourceGroup $ResourceGroupForDeployment `
        -KeyVault $KeyVault `
        -VnetName $VnetName `
        -KvSubnetName $KvSubnetName `
        -PrivateKvEndpointName $privateKvEndpointName `
        -PrivateKvDnsZoneName $privateKvDnsZoneName `
        -PrivateKvLink $privateKvlink `
        -AzCliOutput $azCliOutput
} else {
    Write-Host "   🔵 Skipping Key Vault private endpoint (default). Apps use public Key Vault endpoint with VNet subnet access."
    Write-Host "      ➡️ Re-run with -EnableKeyVaultPrivateEndpoint to add private endpoint hardening later."
}
#endregion



#region Present Output

Write-host "✅ If the intallation completed without error complete the folllowing checklist:"
if ($ISLoginAppProvided) {  #If provided then show the user where to add the landing page in AAD, otherwise script did this already for the user.
	Write-host "   🔵 Add The following URLs to the multi-tenant Landing Page AAD App Registration in Azure Portal:"
	Write-host "      ➡️ https://$WebAppNamePrefix-portal.azurewebsites.net"
	Write-host "      ➡️ https://$WebAppNamePrefix-portal.azurewebsites.net/"
	Write-host "      ➡️ https://$WebAppNamePrefix-portal.azurewebsites.net/Home/Index"
	Write-host "      ➡️ https://$WebAppNamePrefix-portal.azurewebsites.net/Home/Index/"
	Write-host "   🔵 Add The following URLs to the multi-tenant Admin Portal AAD App Registration in Azure Portal:"
	Write-host "      ➡️ https://$WebAppNamePrefix-admin.azurewebsites.net"
	Write-host "      ➡️ https://$WebAppNamePrefix-admin.azurewebsites.net/"
	Write-host "      ➡️ https://$WebAppNamePrefix-admin.azurewebsites.net/Home/Index"
	Write-host "      ➡️ https://$WebAppNamePrefix-admin.azurewebsites.net/Home/Index/"
	Write-host "   🔵 Verify ID Tokens checkbox has been checked-out ?"
}

Write-host "   🔵 Add The following URL in PartnerCenter SaaS Technical Configuration"
Write-host "      ➡️ Landing Page section:       https://$WebAppNamePrefix-portal.azurewebsites.net/"
Write-host "      ➡️ Connection Webhook section: https://$WebAppNamePrefix-portal.azurewebsites.net/api/AzureWebhook"
Write-host "      ➡️ Tenant ID:                  $TenantID"
Write-host "      ➡️ AAD Application ID section: $ADApplicationID"
$duration = (Get-Date) - $startTime
Write-Host "Deployment Complete in $($duration.Minutes)m:$($duration.Seconds)s"
Write-Host "DO NOT CLOSE THIS SCREEN.  Please make sure you copy or perform the actions above before closing."
#endregion
