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
        dotnet restore $project --verbosity quiet
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

function Configure-WebAppDatabaseSettings {
    param(
        [string]$ResourceGroup,
        [string]$WebAppName,
        [string]$ConnectionString,
        [string]$ClientSecret,
        [string]$AzCliOutput = "json"
    )

    Write-Host "      ➡️ Configure PostgreSQL connection for $WebAppName"
    $ErrorActionPreference = 'Continue'
    az webapp config connection-string set `
        --resource-group $ResourceGroup `
        --name $WebAppName `
        --connection-string-type Custom `
        --settings DefaultConnection="$ConnectionString" `
        --output $AzCliOutput | Out-Null
    az webapp config appsettings set `
        --resource-group $ResourceGroup `
        --name $WebAppName `
        --settings "ConnectionStrings__DefaultConnection=$ConnectionString" "SaaSApiConfiguration__ClientSecret=$ClientSecret" "WEBSITE_VNET_ROUTE_ALL=1" `
        --output $AzCliOutput | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to configure database settings for '$WebAppName'." }
    $ErrorActionPreference = 'Stop'
}

function Configure-WebAppKeyVaultReferences {
    param(
        [string]$ResourceGroup,
        [string]$WebAppName,
        [string]$AzCliOutput = "json"
    )

    Write-Host "      ➡️ Enable Key Vault reference resolution for $WebAppName"
    $ErrorActionPreference = 'Continue'
    az webapp update --resource-group $ResourceGroup --name $WebAppName --set keyVaultReferenceIdentity=SystemAssigned --output $AzCliOutput | Out-Null
    az webapp config appsettings set --resource-group $ResourceGroup --name $WebAppName --settings WEBSITE_VNET_ROUTE_ALL=1 --output $AzCliOutput | Out-Null
    $ErrorActionPreference = 'Stop'
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

    $ErrorActionPreference = 'Continue'
    if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
        $PSNativeCommandUseErrorActionPreference = $false
    }
    az webapp vnet-integration add `
        --resource-group $ResourceGroup `
        --name $WebAppName `
        --vnet $VnetName `
        --subnet $SubnetName `
        --output $AzCliOutput 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to add VNet integration for web app '$WebAppName'." }
    $ErrorActionPreference = 'Stop'
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

    if ($myIp -notmatch '/') {
        $myIp = "$myIp/32"
    }

    Write-Host "      ➡️ Temporarily allowing deployer IP $myIp on Key Vault $KeyVault"
    $ErrorActionPreference = 'Continue'
    az keyvault network-rule add --name $KeyVault --resource-group $ResourceGroup --ip-address $myIp --output none
    if ($LASTEXITCODE -ne 0) {
        Write-Host "      ⚠️ Could not add deployer IP rule to Key Vault (exit $LASTEXITCODE)." -ForegroundColor Yellow
    } else {
        Start-Sleep -Seconds 15
    }
    $ErrorActionPreference = 'Stop'
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

function Set-KeyVaultSecretValue {
    param(
        [string]$KeyVault,
        [string]$SecretName,
        [string]$SecretValue,
        [string]$AzCliOutput = "json"
    )

    $secretFile = [System.IO.Path]::GetTempFileName()
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($secretFile, $SecretValue, $utf8NoBom)
        $ErrorActionPreference = 'Continue'
        az keyvault secret set --vault-name $KeyVault --name $SecretName --file $secretFile --encoding utf-8 --output $AzCliOutput | Out-Null
        $ErrorActionPreference = 'Stop'
        if ($LASTEXITCODE -ne 0) { throw "Failed to set Key Vault secret '$SecretName'." }
    } finally {
        Remove-Item -Path $secretFile -Force -ErrorAction SilentlyContinue
    }
}

function Set-KeyVaultSecrets {
    param(
        [string]$KeyVault,
        [string]$ResourceGroup,
        [hashtable]$Secrets,
        [string]$AzCliOutput = "json"
    )

    Write-Host "      ➡️ Temporarily opening Key Vault firewall for secret deployment"
    $ErrorActionPreference = 'Continue'
    az keyvault update --name $KeyVault --resource-group $ResourceGroup --default-action Allow --output none
    if ($LASTEXITCODE -ne 0) { throw "Failed to open Key Vault firewall on '$KeyVault'." }
    Start-Sleep -Seconds 5
    $ErrorActionPreference = 'Stop'

    try {
        foreach ($entry in $Secrets.GetEnumerator()) {
            Set-KeyVaultSecretValue -KeyVault $KeyVault -SecretName $entry.Key -SecretValue ([string]$entry.Value) -AzCliOutput $AzCliOutput
        }
    } finally {
        Write-Host "      ➡️ Restoring Key Vault firewall default action to Deny"
        $ErrorActionPreference = 'Continue'
        az keyvault update --name $KeyVault --resource-group $ResourceGroup --default-action Deny --output none
        $ErrorActionPreference = 'Stop'
    }
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

    $compatScriptPath = Join-Path $DeployTempDir "saas-compat.sql"
    $postgresCompatPath = Join-Path $DeployScriptRoot "postgres/postgres-compat.sql"
    $compatibilityScript = @'
CREATE TABLE IF NOT EXISTS "__EFMigrationsHistory" (
    "MigrationId" character varying(150) NOT NULL,
    "ProductVersion" character varying(32) NOT NULL,
    CONSTRAINT "PK___EFMigrationsHistory" PRIMARY KEY ("MigrationId")
);

'@
    if (Test-Path $postgresCompatPath) {
        $compatibilityScript += (Get-Content -Path $postgresCompatPath -Raw -Encoding UTF8)
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($compatScriptPath, $compatibilityScript, $utf8NoBom)
    & (Join-Path $DeployScriptRoot "postgres/Invoke-PostgresMigration.ps1") `
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
        [string]$HealthPath = "/",
        [int]$MaxAttempts = 20,
        [int]$SleepSeconds = 15
    )

    $url = "https://$WebAppName.azurewebsites.net$HealthPath"
    Write-Host "      ➡️ Health check: $url"

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 45 -ErrorAction Stop
            $body = $response.Content
            if ($response.StatusCode -ge 500) {
                Write-Host "         attempt $attempt/$MaxAttempts HTTP $($response.StatusCode)"
            } elseif ($body -match 'Your web app is running and waiting for your content') {
                Write-Host "         attempt $attempt/$MaxAttempts still showing Azure placeholder page"
            } elseif ($body -match 'Sign in to your account|login\.microsoftonline\.com') {
                Write-Host "      ✅ $WebAppName responded with sign-in page." -ForegroundColor Green
                return
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
