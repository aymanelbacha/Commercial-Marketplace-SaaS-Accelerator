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

$resolvedScriptPath = Resolve-Path -Path $ScriptPath
if (-not (Test-Path $resolvedScriptPath)) {
    throw "Migration script not found: $ScriptPath"
}

$sql = Get-Content -Path $resolvedScriptPath -Raw -Encoding UTF8
if ([string]::IsNullOrWhiteSpace($sql)) {
    throw "Migration script is empty: $resolvedScriptPath"
}

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
$result = az vm run-command invoke `
    --resource-group $ResourceGroup `
    --name $VmName `
    --command-id RunShellScript `
    --scripts $remoteScript `
    --output json | ConvertFrom-Json

$stdout = $result.value[0].message
$stderr = $result.value[0].stderr
if ($stdout) { Write-Host $stdout }
if ($stderr -and $stderr -notmatch '^\s*$') {
    Write-Host $stderr -ForegroundColor Yellow
}

if ($stderr -match 'ERROR:|FATAL:|psql:.* error:') {
    throw "Database migration failed on VM '$VmName'. See output above."
}

Write-Host "      ✅ Database migration applied." -ForegroundColor Green
