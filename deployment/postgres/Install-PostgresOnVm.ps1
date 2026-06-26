# Installs PostgreSQL on a VM via a single blocking Run Command.
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $VmName,
    [Parameter(Mandatory)] [string] $DeployScriptRoot,
    [Parameter(Mandatory)] [string] $DatabaseName,
    [Parameter(Mandatory)] [string] $DatabaseUser,
    [Parameter(Mandatory)] [string] $DatabasePassword,
    [Parameter(Mandatory)] [string] $VnetCidr,
    [Parameter()] [string] $DeployTempDir = $env:TEMP
)

$ErrorActionPreference = "Stop"

$templatePath = Join-Path $DeployScriptRoot "install-postgres.sh.template"
if (-not (Test-Path $templatePath)) {
    throw "Install template not found: $templatePath"
}

$installScript = Get-Content -Path $templatePath -Raw
$installScript = $installScript.Replace("__DB_NAME__", $DatabaseName)
$installScript = $installScript.Replace("__DB_USER__", $DatabaseUser)
$installScript = $installScript.Replace("__DB_PASSWORD__", $DatabasePassword.Replace("'", "'\''"))
$installScript = $installScript.Replace("__VNET_CIDR__", $VnetCidr)
$installScript = $installScript.Replace("`r`n", "`n").Replace("`r", "`n")

$localScriptPath = Join-Path $DeployTempDir "$VmName-install-postgres.sh"
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($localScriptPath, $installScript, $utf8NoBom)

Write-Host "      Installing PostgreSQL on VM $VmName (blocking, ~2-3 min)..."
$ErrorActionPreference = 'Continue'
az vm run-command invoke `
    --resource-group $ResourceGroup `
    --name $VmName `
    --command-id RunShellScript `
    --scripts "@$localScriptPath" `
    --output none 2>$null | Out-Null
$exit = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
Remove-Item -Path $localScriptPath -Force -ErrorAction SilentlyContinue

if ($exit -ne 0) {
    throw "PostgreSQL install command failed on VM '$VmName' (exit $exit)."
}

$ErrorActionPreference = 'Continue'
$verifyJson = az vm run-command invoke `
    --resource-group $ResourceGroup `
    --name $VmName `
    --command-id RunShellScript `
    --scripts "grep -q 'bootstrap finished' /var/log/saas-postgres-install.log && echo OK || (tail -20 /var/log/saas-postgres-install.log 2>/dev/null; echo FAIL)" `
    --output json 2>$null | Out-String
$ErrorActionPreference = 'Stop'

if ($LASTEXITCODE -ne 0 -or $verifyJson -notmatch 'OK') {
    $detail = if ($verifyJson) { ($verifyJson | ConvertFrom-Json).value[0].message } else { "no output" }
    throw "PostgreSQL install did not complete on VM '$VmName'. $detail"
}

Write-Host "      PostgreSQL install completed on VM $VmName." -ForegroundColor Green
