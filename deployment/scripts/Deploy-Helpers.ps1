# Shared helpers for Deploy.ps1 and Upgrade.ps1

function Ensure-DotNetEfTool {
    $efVersion = dotnet ef --version 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($efVersion)) {
        Write-Host "      ➡️ Installing dotnet-ef global tool"
        dotnet tool install --global dotnet-ef --version 8.0.6
        $userHome = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
        $dotnetToolsPath = Join-Path $userHome ".dotnet/tools"
        if (Test-Path $dotnetToolsPath) {
            $env:PATH = "$dotnetToolsPath$([IO.Path]::PathSeparator)$env:PATH"
        }
    }
}

function Test-SolutionBuild {
    param([string]$RepoRoot)

    Write-Host "      ➡️ Validating solution build before Azure deployment..."
    $projects = @(
        (Join-Path $RepoRoot "src/DataAccess/DataAccess.csproj"),
        (Join-Path $RepoRoot "src/Services/Services.csproj"),
        (Join-Path $RepoRoot "src/AdminSite/AdminSite.csproj"),
        (Join-Path $RepoRoot "src/CustomerSite/CustomerSite.csproj")
    )

    dotnet restore (Join-Path $RepoRoot "src/AdminSite/AdminSite.csproj") --verbosity quiet
    foreach ($project in $projects) {
        if (-not (Test-Path $project)) {
            throw "Required project not found: $project"
        }
        dotnet build $project -c Release --no-restore --verbosity quiet
        if ($LASTEXITCODE -ne 0) {
            throw "Build failed for $project. Fix compile errors before deploying."
        }
    }
    Write-Host "      ✅ Solution build validation passed." -ForegroundColor Green
}

function Build-PublishPackages {
    param(
        [string]$RepoRoot,
        [string]$PublishRoot,
        [string]$AdminPublishDir,
        [string]$PortalPublishDir,
        [string]$AdminZipPath,
        [string]$PortalZipPath
    )

    Write-Host "   🔵 Preparing Admin Site"
    dotnet publish (Join-Path $RepoRoot "src/AdminSite/AdminSite.csproj") -c Release -o $AdminPublishDir -v q

    Write-Host "   🔵 Preparing Metered Scheduler"
    $meteredJobDir = Join-Path $AdminPublishDir "app_data/jobs/triggered/MeteredTriggerJob"
    dotnet publish (Join-Path $RepoRoot "src/MeteredTriggerJob/MeteredTriggerJob.csproj") -c Release -o $meteredJobDir -v q --runtime win-x64 --self-contained true

    Write-Host "   🔵 Preparing Customer Site"
    dotnet publish (Join-Path $RepoRoot "src/CustomerSite/CustomerSite.csproj") -c Release -o $PortalPublishDir -v q

    Write-Host "   🔵 Zipping packages"
    if (Test-Path $AdminZipPath) { Remove-Item $AdminZipPath -Force }
    if (Test-Path $PortalZipPath) { Remove-Item $PortalZipPath -Force }
    Compress-Archive -Path (Join-Path $AdminPublishDir "*") -DestinationPath $AdminZipPath -Force
    Compress-Archive -Path (Join-Path $PortalPublishDir "*") -DestinationPath $PortalZipPath -Force
}

function Add-WebAppVnetIntegration {
    param(
        [string]$ResourceGroup,
        [string]$WebAppName,
        [string]$VnetName,
        [string]$SubnetName,
        [string]$AzCliOutput = "json"
    )

    $existing = az webapp vnet-integration list -g $ResourceGroup -n $WebAppName --query "[0].name" -o tsv 2>$null
    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        Write-Host "      ➡️ VNet integration already configured for $WebAppName"
        return
    }

    az webapp vnet-integration add `
        --resource-group $ResourceGroup `
        --name $WebAppName `
        --vnet $VnetName `
        --subnet $SubnetName `
        --output $AzCliOutput
}

function Enable-DeployerKeyVaultAccess {
    param(
        [string]$KeyVault,
        [string]$ResourceGroup
    )

    try {
        $myIp = (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 15).Trim()
    } catch {
        Write-Host "      ⚠️ Could not detect public IP for Key Vault access. Secret reads may fail if firewall is locked down." -ForegroundColor Yellow
        return $null
    }

    Write-Host "      ➡️ Temporarily allowing deployer IP $myIp on Key Vault $KeyVault"
    az keyvault network-rule add --name $KeyVault --resource-group $ResourceGroup --ip-address $myIp --output none 2>$null
    return $myIp
}

function Disable-DeployerKeyVaultAccess {
    param(
        [string]$KeyVault,
        [string]$ResourceGroup,
        [string]$IpAddress
    )

    if ([string]::IsNullOrWhiteSpace($IpAddress)) { return }
    Write-Host "      ➡️ Removing temporary deployer IP $IpAddress from Key Vault $KeyVault"
    az keyvault network-rule remove --name $KeyVault --resource-group $ResourceGroup --ip-address $IpAddress --output none 2>$null
}

function Get-KeyVaultSecretValue {
    param(
        [string]$KeyVault,
        [string]$SecretName,
        [string]$ResourceGroup
    )

    $tempIp = Enable-DeployerKeyVaultAccess -KeyVault $KeyVault -ResourceGroup $ResourceGroup
    try {
        return az keyvault secret show --vault-name $KeyVault --name $SecretName --query value -o tsv
    } finally {
        Disable-DeployerKeyVaultAccess -KeyVault $KeyVault -ResourceGroup $ResourceGroup -IpAddress $tempIp
    }
}

function Invoke-PostgresCompatibilityMigration {
    param(
        [string]$DeployScriptRoot,
        [string]$DeployTempDir,
        [string]$ResourceGroup,
        [string]$VmName,
        [string]$DatabaseName,
        [string]$DatabaseUser,
        [string]$DatabasePassword
    )

    . (Join-Path $DeployScriptRoot "postgres/Invoke-PostgresMigration.ps1")
    $compatScriptPath = Join-Path $DeployTempDir "saas-compat.sql"
    $compatibilityScript = @"
CREATE TABLE IF NOT EXISTS ""__EFMigrationsHistory"" (
    ""MigrationId"" character varying(150) NOT NULL,
    ""ProductVersion"" character varying(32) NOT NULL,
    CONSTRAINT ""PK___EFMigrationsHistory"" PRIMARY KEY (""MigrationId"")
);
"@
    Set-Content -Path $compatScriptPath -Value $compatibilityScript -Encoding UTF8
    Invoke-PostgresMigration `
        -ResourceGroup $ResourceGroup `
        -VmName $VmName `
        -DatabaseName $DatabaseName `
        -DatabaseUser $DatabaseUser `
        -DatabasePassword $DatabasePassword `
        -ScriptPath $compatScriptPath
    Remove-Item -Path $compatScriptPath -Force -ErrorAction SilentlyContinue
}

function Test-WebAppDeploymentHealth {
    param(
        [string]$WebAppName,
        [int]$MaxAttempts = 20,
        [int]$SleepSeconds = 15
    )

    $url = "https://$WebAppName.azurewebsites.net/"
    Write-Host "      ➡️ Health check: $url"

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 45 -ErrorAction Stop
            $body = $response.Content
            if ($response.StatusCode -ge 500) {
                Write-Host "         attempt $attempt/$MaxAttempts HTTP $($response.StatusCode)"
            } elseif ($body -match 'Your web app is running and waiting for your content') {
                Write-Host "         attempt $attempt/$MaxAttempts still showing Azure placeholder page"
            } else {
                Write-Host "      ✅ $WebAppName responded without placeholder page." -ForegroundColor Green
                return
            }
        } catch {
            Write-Host "         attempt $attempt/$MaxAttempts $($_.Exception.Message)"
        }

        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds $SleepSeconds
        }
    }

    throw "Health check failed for $url after $($MaxAttempts * $SleepSeconds) seconds."
}

function Install-KeyVaultPrivateEndpoint {
    param(
        [string]$ResourceGroup,
        [string]$KeyVault,
        [string]$VnetName,
        [string]$KvSubnetName,
        [string]$PrivateKvEndpointName,
        [string]$PrivateKvDnsZoneName,
        [string]$PrivateKvLink,
        [string]$AzCliOutput = "json"
    )

    Write-Host "   🔵 Optional: Configure Key Vault private endpoint"
    $keyVaultId = az keyvault show --name $KeyVault --resource-group $ResourceGroup --query id -o tsv
    az network private-endpoint create `
        --name $PrivateKvEndpointName `
        --resource-group $ResourceGroup `
        --vnet-name $VnetName `
        --subnet $KvSubnetName `
        --private-connection-resource-id $keyVaultId `
        --group-ids vault `
        --connection-name kvConnection `
        --output $AzCliOutput

    az network private-dns zone create --name $PrivateKvDnsZoneName --resource-group $ResourceGroup --output $AzCliOutput
    az network private-dns link vnet create `
        --name $PrivateKvLink `
        --resource-group $ResourceGroup `
        --virtual-network $VnetName `
        --zone-name $PrivateKvDnsZoneName `
        --registration-enabled false `
        --output $AzCliOutput
    az network private-endpoint dns-zone-group create `
        --resource-group $ResourceGroup `
        --endpoint-name $PrivateKvEndpointName `
        --name "Kv-zone-group" `
        --private-dns-zone $PrivateKvDnsZoneName `
        --zone-name "Kv-zone" `
        --output $AzCliOutput

    Write-Host "      ➡️ Waiting 90s for Key Vault private DNS propagation..."
    Start-Sleep -Seconds 90
}
