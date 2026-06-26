# Deprecated: use Ensure-PostgresReady.ps1 instead.
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $VmName,
    [Parameter()] [string] $DatabaseUser = "saasadmin",
    [Parameter()] [string] $DatabasePassword = "",
    [Parameter()] [string] $DatabaseName = "",
    [Parameter()] [int] $MaxAttempts = 3,
    [Parameter()] [int] $SleepSeconds = 10
)

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $scriptRoot "Ensure-PostgresReady.ps1") `
    -ResourceGroup $ResourceGroup `
    -VmName $VmName `
    -DeployScriptRoot $scriptRoot `
    -DatabaseName $DatabaseName `
    -DatabaseUser $DatabaseUser `
    -DatabasePassword $DatabasePassword `
    -VnetCidr "10.0.0.0/20" `
    -VerifyAttempts $MaxAttempts `
    -VerifySleepSeconds $SleepSeconds
