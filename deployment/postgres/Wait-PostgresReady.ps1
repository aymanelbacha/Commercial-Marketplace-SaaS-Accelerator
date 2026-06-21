# Polls a PostgreSQL VM until postgresql service and login are ready.
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $VmName,
    [Parameter()] [string] $DatabaseUser = "saasadmin",
    [Parameter()] [string] $DatabasePassword = "",
    [Parameter()] [string] $DatabaseName = "",
    [Parameter()] [int] $MaxAttempts = 24,
    [Parameter()] [int] $SleepSeconds = 15
)

$ErrorActionPreference = "Stop"

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    Write-Host "      ➡️ Waiting for PostgreSQL bootstrap (attempt $attempt/$MaxAttempts)..."

    $probeScript = @"
set -e
systemctl is-active postgresql
test -S /var/run/postgresql/16-main.pid || test -S /var/run/postgresql/.s.PGSQL.5432
"@

    if (-not [string]::IsNullOrWhiteSpace($DatabasePassword) -and -not [string]::IsNullOrWhiteSpace($DatabaseName)) {
        $escapedPassword = $DatabasePassword.Replace("'", "'\''")
        $probeScript += @"

export PGPASSWORD='$escapedPassword'
psql -h 127.0.0.1 -U '$DatabaseUser' -d '$DatabaseName' -tAc 'SELECT 1'
"@
    }

    $result = az vm run-command invoke `
        --resource-group $ResourceGroup `
        --name $VmName `
        --command-id RunShellScript `
        --scripts $probeScript `
        --output json 2>$null | ConvertFrom-Json

    $message = $result.value[0].message
    $serviceReady = $message -match "active"
    $dbReady = $true
    if (-not [string]::IsNullOrWhiteSpace($DatabaseName)) {
        $dbReady = $message -match '(?m)^1\s*$'
    }

    if ($serviceReady -and $dbReady) {
        Write-Host "      ✅ PostgreSQL is ready on VM $VmName." -ForegroundColor Green
        return
    }

    if ($attempt -lt $MaxAttempts) {
        Start-Sleep -Seconds $SleepSeconds
    }
}

$logResult = az vm run-command invoke `
    --resource-group $ResourceGroup `
    --name $VmName `
    --command-id RunShellScript `
    --scripts "tail -80 /var/log/cloud-init-output.log 2>/dev/null; echo '---'; tail -80 /var/log/saas-postgres-install.log 2>/dev/null" `
    --output json 2>$null | ConvertFrom-Json
if ($logResult.value[0].message) {
    Write-Host $logResult.value[0].message
}

throw "PostgreSQL on VM '$VmName' did not become ready within $($MaxAttempts * $SleepSeconds) seconds. Check cloud-init and saas-postgres-install logs on the VM."
