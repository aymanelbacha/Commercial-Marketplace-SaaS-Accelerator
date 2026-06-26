# Quick PostgreSQL check: verify login, install only if needed (no long polling).
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $VmName,
    [Parameter(Mandatory)] [string] $DeployScriptRoot,
    [Parameter(Mandatory)] [string] $DatabaseName,
    [Parameter(Mandatory)] [string] $DatabaseUser,
    [Parameter(Mandatory)] [string] $DatabasePassword,
    [Parameter(Mandatory)] [string] $VnetCidr
)

function Invoke-VmShell {
    param([string] $Script)
    $ErrorActionPreference = 'Continue'
    $raw = az vm run-command invoke `
        --resource-group $ResourceGroup `
        --name $VmName `
        --command-id RunShellScript `
        --scripts $Script `
        --output json 2>$null | Out-String
    $exit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($exit -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) { return $null }
    return (($raw | ConvertFrom-Json).value[0].message)
}

function Test-PostgresLogin {
    $escapedPassword = $DatabasePassword.Replace("'", "'\''")
    $result = Invoke-VmShell @"
export PGPASSWORD='$escapedPassword'
systemctl is-active postgresql
psql -h 127.0.0.1 -U '$DatabaseUser' -d '$DatabaseName' -tAc 'SELECT 1'
"@
    return ($null -ne $result -and $result -match 'active' -and $result -match '(?m)\b1\b')
}

Write-Host "      Checking PostgreSQL on VM $VmName..."
if (Test-PostgresLogin) {
    Write-Host "      PostgreSQL is ready." -ForegroundColor Green
    return
}

Write-Host "      Installing PostgreSQL (one blocking step, ~3 min)..."
& (Join-Path $DeployScriptRoot "Install-PostgresOnVm.ps1") `
    -ResourceGroup $ResourceGroup `
    -VmName $VmName `
    -DeployScriptRoot $DeployScriptRoot `
    -DatabaseName $DatabaseName `
    -DatabaseUser $DatabaseUser `
    -DatabasePassword $DatabasePassword `
    -VnetCidr $VnetCidr `
    -DeployTempDir $env:TEMP

if (-not (Test-PostgresLogin)) {
    throw "PostgreSQL is not accepting connections on VM '$VmName' after install."
}
Write-Host "      PostgreSQL is ready." -ForegroundColor Green
