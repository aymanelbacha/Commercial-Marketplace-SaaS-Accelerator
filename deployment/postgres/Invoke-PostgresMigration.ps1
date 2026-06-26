# Runs a SQL migration script on a private PostgreSQL VM via Azure Run Command.
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $VmName,
    [Parameter(Mandatory)] [string] $DatabaseName,
    [Parameter(Mandatory)] [string] $DatabaseUser,
    [Parameter(Mandatory)] [string] $DatabasePassword,
    [Parameter(Mandatory)] [string] $ScriptPath,
    [Parameter()] [string] $DeployTempDir = $env:TEMP
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

$sql = $sql.Replace("`r`n", "`n").Replace("`r", "`n")
$escapedPassword = $DatabasePassword.Replace("'", "'\''")
$delimiter = "SAAS_MIGRATE_EOF_$(Get-Random)"

$runnerScript = @"
#!/bin/bash
set -e
export PGPASSWORD='$escapedPassword'
cat > /tmp/saas-migrate.sql <<'$delimiter'
$sql
$delimiter
psql -h 127.0.0.1 -U '$DatabaseUser' -d '$DatabaseName' -v ON_ERROR_STOP=1 -f /tmp/saas-migrate.sql
rm -f /tmp/saas-migrate.sql
echo MIGRATION_OK
"@

$runnerScript = $runnerScript.Replace("`r`n", "`n").Replace("`r", "`n")
$runnerPath = Join-Path $DeployTempDir "$VmName-migrate-$(Get-Random).sh"
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($runnerPath, $runnerScript, $utf8NoBom)

Write-Host "      Applying database migration on VM $VmName via Run Command..."
$ErrorActionPreference = 'Continue'
$resultJson = az vm run-command invoke `
    --resource-group $ResourceGroup `
    --name $VmName `
    --command-id RunShellScript `
    --scripts "@$runnerPath" `
    --output json 2>$null | Out-String
$exit = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
Remove-Item -Path $runnerPath -Force -ErrorAction SilentlyContinue

if ($exit -ne 0 -or [string]::IsNullOrWhiteSpace($resultJson)) {
    throw "Database migration command failed on VM '$VmName'."
}

$output = ($resultJson | ConvertFrom-Json).value[0].message
if ($output -notmatch 'MIGRATION_OK') {
    if ($output) { Write-Host $output }
    throw "Database migration failed on VM '$VmName'. See output above."
}

Write-Host "      Database migration applied." -ForegroundColor Green
