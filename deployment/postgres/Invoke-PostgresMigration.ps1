# Runs a SQL migration script on a private PostgreSQL VM via Azure Run Command.
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $VmName,
    [Parameter(Mandatory)] [string] $DatabaseName,
    [Parameter(Mandatory)] [string] $DatabaseUser,
    [Parameter(Mandatory)] [string] $DatabasePassword,
    [Parameter(Mandatory)] [string] $ScriptPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ScriptPath)) {
    throw "Migration script not found: $ScriptPath"
}

$sql = Get-Content -Path $ScriptPath -Raw -Encoding UTF8
$sqlB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sql))
$escapedPassword = $DatabasePassword.Replace("'", "'\''")

$remoteScript = @"
set -euo pipefail
echo '$sqlB64' | base64 -d > /tmp/saas-migrate.sql
export PGPASSWORD='$escapedPassword'
psql -h 127.0.0.1 -U '$DatabaseUser' -d '$DatabaseName' -v ON_ERROR_STOP=1 -f /tmp/saas-migrate.sql
rm -f /tmp/saas-migrate.sql
"@

Write-Host "      ➡️ Applying database migration on VM $VmName via Run Command..."
az vm run-command invoke `
    --resource-group $ResourceGroup `
    --name $VmName `
    --command-id RunShellScript `
    --scripts $remoteScript `
    --output none

Write-Host "      ✅ Database migration applied." -ForegroundColor Green
