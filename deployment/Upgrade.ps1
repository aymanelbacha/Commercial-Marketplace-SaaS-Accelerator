# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License. See LICENSE file in the project root for license information.

#
# Powershell script to upgrade Customer portal, Publisher portal and PostgreSQL database on private Linux VM
#

Param(  
   [string][Parameter(Mandatory)]$WebAppNamePrefix,
   [string][Parameter(Mandatory)]$ResourceGroupForDeployment
)

$message = @"
The SaaS Accelerator is offered under the MIT License as open source software and is not supported by Microsoft.

If you need help with the accelerator or would like to report defects or feature requests use the Issues feature on the GitHub repository at https://aka.ms/SaaSAccelerator

Do you agree? (Y/N)
"@

Write-Host $message -ForegroundColor Yellow
$response = Read-Host
if ($response -ne 'Y' -and $response -ne 'y') {
    Write-Host "You did not agree. Exiting..." -ForegroundColor Red
    exit
}

Write-Host "Thank you for agreeing. Proceeding with the script..." -ForegroundColor Green

$currentContext = az account show | ConvertFrom-Json
$AzureSubscriptionID = $currentContext.id
az account set -s $AzureSubscriptionID
Write-Host "🔑 Azure Subscription '$AzureSubscriptionID' selected."

$ErrorActionPreference = "Stop"
$DeployScriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
$DeployTempDir = if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) {
    $env:TEMP
} elseif (-not [string]::IsNullOrWhiteSpace($env:TMPDIR)) {
    $env:TMPDIR
} else {
    [System.IO.Path]::GetTempPath().TrimEnd([char]'/', [char]'\')
}
$WebAppNameAdmin=$WebAppNamePrefix+"-admin"
$WebAppNamePortal=$WebAppNamePrefix+"-portal"
$KeyVault=$WebAppNamePrefix+"-kv"
$SQLDatabaseName = $WebAppNamePrefix +"AMPSaaSDB"
$PostgresVmName = $WebAppNamePrefix + "-pgvm"
$PostgresAdminUser = "saasadmin"

#region Deploy Database

Write-host "#### STEP 1 Database deployment start####"

Write-host "## STEP 1.1 Retrieve connection string and VM credentials from Key Vault"
$ConnectionString = az keyvault secret show --vault-name $KeyVault --name "DefaultConnection" --query value -o tsv
$PostgresAdminPassword = az keyvault secret show --vault-name $KeyVault --name "PostgresAdminPassword" --query value -o tsv

Write-host "## STEP 1.2 Update connection string in AdminSite project"
Set-Content -Path ../src/AdminSite/appsettings.Development.json -value "{`"ConnectionStrings`": {`"DefaultConnection`":`"$ConnectionString`"}}"

Write-host "## STEP 1.3 Generate PostgreSQL migration script"
dotnet-ef migrations script `
    --idempotent `
    --context SaaSKitContext `
    --project ../src/DataAccess/DataAccess.csproj `
    --startup-project ../src/AdminSite/AdminSite.csproj `
    --output script.sql

$compatibilityScript = @"
CREATE TABLE IF NOT EXISTS ""__EFMigrationsHistory"" (
    ""MigrationId"" character varying(150) NOT NULL,
    ""ProductVersion"" character varying(32) NOT NULL,
    CONSTRAINT ""PK___EFMigrationsHistory"" PRIMARY KEY (""MigrationId"")
);
"@

Write-host "## STEP 1.4 Apply compatibility script on PostgreSQL VM"
. (Join-Path $DeployScriptRoot "postgres/Invoke-PostgresMigration.ps1")
$compatPath = Join-Path $DeployTempDir "saas-compat.sql"
Set-Content -Path $compatPath -Value $compatibilityScript -Encoding UTF8
Invoke-PostgresMigration `
    -ResourceGroup $ResourceGroupForDeployment `
    -VmName $PostgresVmName `
    -DatabaseName $SQLDatabaseName `
    -DatabaseUser $PostgresAdminUser `
    -DatabasePassword $PostgresAdminPassword `
    -ScriptPath $compatPath
Remove-Item $compatPath -Force

Write-host "## STEP 1.5 Apply migration script on PostgreSQL VM"
Invoke-PostgresMigration `
    -ResourceGroup $ResourceGroupForDeployment `
    -VmName $PostgresVmName `
    -DatabaseName $SQLDatabaseName `
    -DatabaseUser $PostgresAdminUser `
    -DatabasePassword $PostgresAdminPassword `
    -ScriptPath "./script.sql"

Remove-Item -Path ../src/AdminSite/appsettings.Development.json
Remove-Item -Path script.sql

Write-host "#### Database Deployment complete ####"	

#endregion Deploy Database

#region Deploy code

Write-host "#### STEP 2 Deploying new code ####" 

Write-host "## STEP 2.1 Building Admin Portal" 
dotnet publish ../src/AdminSite/AdminSite.csproj -v q -c release -o ../Publish/AdminSite/

Write-host "## STEP 2.2 Building Meter Scheduler"
dotnet publish ../src/MeteredTriggerJob/MeteredTriggerJob.csproj -c release -o ../Publish/AdminSite/app_data/jobs/triggered/MeteredTriggerJob/ --runtime win-x64 --self-contained true -p:PublishReadyToRun=false

Write-host "## STEP 2.3 Building Customer Portal" 
dotnet publish ../src/CustomerSite/CustomerSite.csproj -v q -c release -o ../Publish/CustomerSite

Write-host "## STEP 2.4 Compress packages." 
Compress-Archive -Path ../Publish/CustomerSite/* -DestinationPath ../Publish/CustomerSite.zip -Force
Compress-Archive -Path ../Publish/AdminSite/* -DestinationPath ../Publish/AdminSite.zip -Force

Write-host "## STEP 2.5 Deploying code to Admin Portal"
az webapp deploy `
	--resource-group $ResourceGroupForDeployment `
	--name $WebAppNameAdmin `
	--src-path "../Publish/AdminSite.zip" `
	--type zip
Write-host "## Deployed code to Admin Portal"

Write-host "## STEP 2.6 Deploying code to Customer Portal"
az webapp deploy `
	--resource-group $ResourceGroupForDeployment `
	--name $WebAppNamePortal `
	--src-path "../Publish/CustomerSite.zip"  `
	--type zip
Write-host "## Deployed code to Customer Portal"

#endregion Deploy code

Remove-Item -Path ../Publish -recurse -Force
Write-host "#### Code deployment complete ####" 
Write-host ""
Write-host "#### The upgrade process has completed successfully ####" 
Write-host ""
Write-host "#### Warning!!! ####"
Write-host "#### If the upgrade is to >=7.5.0, MeterScheduler feature is pre-enabled and changed to DB config instead of the App Service configuration. Please update the IsMeteredBillingEnabled value accordingly in the Admin portal -> Settings page. ####"
Write-host "#### "
