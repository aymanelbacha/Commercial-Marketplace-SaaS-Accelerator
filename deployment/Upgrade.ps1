# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License. See LICENSE file in the project root for license information.

#
# Powershell script to upgrade Customer portal, Publisher portal and PostgreSQL database on private Linux VM
#

Param(  
   [string][Parameter(Mandatory)]$WebAppNamePrefix,
   [string][Parameter(Mandatory)]$ResourceGroupForDeployment,
   [switch][Parameter()]$SkipBuild
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
$RepoRoot = Join-Path $DeployScriptRoot ".."
$PublishRoot = Join-Path $RepoRoot "Publish"
$AdminPublishDir = Join-Path $PublishRoot "AdminSite"
$PortalPublishDir = Join-Path $PublishRoot "CustomerSite"
$AdminZipPath = Join-Path $PublishRoot "AdminSite.zip"
$PortalZipPath = Join-Path $PublishRoot "CustomerSite.zip"
$MigrationScriptPath = Join-Path $DeployScriptRoot "script.sql"
$DevAppSettingsPath = Join-Path $RepoRoot "src/AdminSite/appsettings.Development.json"

. (Join-Path $DeployScriptRoot "scripts/Deploy-Helpers.ps1")

$currentContext = az account show | ConvertFrom-Json
$AzureSubscriptionID = $currentContext.id
az account set -s $AzureSubscriptionID
Write-Host "🔑 Azure Subscription '$AzureSubscriptionID' selected."

$WebAppNameAdmin = $WebAppNamePrefix + "-admin"
$WebAppNamePortal = $WebAppNamePrefix + "-portal"
$VnetName = $WebAppNamePrefix + "-vnet"
$KeyVault = $WebAppNamePrefix + "-kv"
$SQLDatabaseName = $WebAppNamePrefix + "AMPSaaSDB"
$PostgresVmName = $WebAppNamePrefix + "-pgvm"
$PostgresAdminUser = "saasadmin"

Ensure-DotNetEfTool
if (-not $SkipBuild) {
    Test-SolutionBuild -RepoRoot $RepoRoot
}

#region Deploy Database

Write-Host "#### STEP 1 Database deployment start ####"

Write-Host "## STEP 1.1 Retrieve connection string and VM credentials from Key Vault"
$ConnectionString = Get-KeyVaultSecretValue -KeyVault $KeyVault -SecretName "DefaultConnection" -ResourceGroup $ResourceGroupForDeployment
$PostgresAdminPassword = Get-KeyVaultSecretValue -KeyVault $KeyVault -SecretName "PostgresAdminPassword" -ResourceGroup $ResourceGroupForDeployment

if ([string]::IsNullOrWhiteSpace($ConnectionString)) {
    throw "DefaultConnection secret is empty or unavailable in Key Vault '$KeyVault'."
}
if ([string]::IsNullOrWhiteSpace($PostgresAdminPassword)) {
    throw "PostgresAdminPassword secret is empty or unavailable in Key Vault '$KeyVault'."
}

Write-Host "## STEP 1.2 Update connection string in AdminSite project"
Set-Content -Path $DevAppSettingsPath -Value "{`"ConnectionStrings`": {`"DefaultConnection`":`"$ConnectionString`"}}"

Write-Host "## STEP 1.3 Generate PostgreSQL migration script"
dotnet ef migrations script `
    --idempotent `
    --context SaaSKitContext `
    --project (Join-Path $RepoRoot "src/DataAccess/DataAccess.csproj") `
    --startup-project (Join-Path $RepoRoot "src/AdminSite/AdminSite.csproj") `
    --output $MigrationScriptPath

Write-Host "## STEP 1.4 Apply compatibility script on PostgreSQL VM"
Invoke-PostgresCompatibilityMigration `
    -DeployScriptRoot $DeployScriptRoot `
    -DeployTempDir $DeployTempDir `
    -ResourceGroup $ResourceGroupForDeployment `
    -VmName $PostgresVmName `
    -DatabaseName $SQLDatabaseName `
    -DatabaseUser $PostgresAdminUser `
    -DatabasePassword $PostgresAdminPassword

Write-Host "## STEP 1.5 Apply migration script on PostgreSQL VM"
. (Join-Path $DeployScriptRoot "postgres/Invoke-PostgresMigration.ps1")
Invoke-PostgresMigration `
    -ResourceGroup $ResourceGroupForDeployment `
    -VmName $PostgresVmName `
    -DatabaseName $SQLDatabaseName `
    -DatabaseUser $PostgresAdminUser `
    -DatabasePassword $PostgresAdminPassword `
    -ScriptPath $MigrationScriptPath

Remove-Item -Path $DevAppSettingsPath -ErrorAction SilentlyContinue
Remove-Item -Path $MigrationScriptPath -ErrorAction SilentlyContinue

Write-Host "#### Database Deployment complete ####"

#endregion Deploy Database

#region Deploy code

Write-Host "#### STEP 2 Deploying new code ####"

Write-Host "## STEP 2.1 Ensure VNet integration"
Add-WebAppVnetIntegration -ResourceGroup $ResourceGroupForDeployment -WebAppName $WebAppNamePortal -VnetName $VnetName -SubnetName "web" -AzCliOutput "none"
Add-WebAppVnetIntegration -ResourceGroup $ResourceGroupForDeployment -WebAppName $WebAppNameAdmin -VnetName $VnetName -SubnetName "web" -AzCliOutput "none"

if (-not $SkipBuild) {
    Write-Host "## STEP 2.2 Build publish packages"
    Build-PublishPackages `
        -RepoRoot $RepoRoot `
        -PublishRoot $PublishRoot `
        -AdminPublishDir $AdminPublishDir `
        -PortalPublishDir $PortalPublishDir `
        -AdminZipPath $AdminZipPath `
        -PortalZipPath $PortalZipPath
} elseif (-not (Test-Path $AdminZipPath) -or -not (Test-Path $PortalZipPath)) {
    throw "SkipBuild was set but publish packages were not found."
}

Write-Host "## STEP 2.3 Deploying code to Admin Portal"
if (-not (Test-Path $AdminZipPath)) { throw "Admin publish package not found: $AdminZipPath" }
az webapp deploy `
    --resource-group $ResourceGroupForDeployment `
    --name $WebAppNameAdmin `
    --src-path $AdminZipPath `
    --type zip `
    --output none

Write-Host "## STEP 2.4 Deploying code to Customer Portal"
if (-not (Test-Path $PortalZipPath)) { throw "Customer publish package not found: $PortalZipPath" }
az webapp deploy `
    --resource-group $ResourceGroupForDeployment `
    --name $WebAppNamePortal `
    --src-path $PortalZipPath `
    --type zip `
    --output none

Write-Host "## STEP 2.5 Restart and verify web apps"
az webapp restart -g $ResourceGroupForDeployment -n $WebAppNameAdmin --output none
az webapp restart -g $ResourceGroupForDeployment -n $WebAppNamePortal --output none
Test-WebAppDeploymentHealth -WebAppName $WebAppNamePortal
Test-WebAppDeploymentHealth -WebAppName $WebAppNameAdmin

Remove-Item -Path $PublishRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "#### Code deployment complete ####"

#endregion Deploy code

Write-Host ""
Write-Host "#### The upgrade process has completed successfully ####"
Write-Host ""
Write-Host "#### Warning!!! ####"
Write-Host "#### If the upgrade is to >=7.5.0, MeterScheduler feature is pre-enabled and changed to DB config instead of the App Service configuration. Please update the IsMeteredBillingEnabled value accordingly in the Admin portal -> Settings page. ####"
