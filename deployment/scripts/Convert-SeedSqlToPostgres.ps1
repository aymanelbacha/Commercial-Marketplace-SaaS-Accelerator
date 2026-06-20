# Converts T-SQL patterns in Custom seed migrations to PostgreSQL.
$root = Join-Path $PSScriptRoot "..\..\src\DataAccess\Migrations\Custom"
$files = Get-ChildItem -Path $root -Filter "*.cs" | Where-Object { $_.Name -ne "PostgresStoredProcedures.cs" }

foreach ($file in $files) {
    $content = Get-Content -Path $file.FullName -Raw -Encoding UTF8
    $original = $content

    $content = $content -replace '\[dbo\]\.', ''
    $content = $content -replace '\[dbo\]', ''
    $content = $content -replace '\[([A-Za-z][A-Za-z0-9_]*)\]', '"$1"'
    $content = $content -replace 'GetDate\(\)', 'NOW()'
    $content = $content -replace '\bGO\b\r?\n?', ''
    $content = $content -replace " N'", " '"
    $content = $content -replace '\bBEGIN\b\r?\n', ''
    $content = $content -replace '\bEND\b\r?\n?', ''
    $content = $content -replace 'IF NOT EXISTS \(SELECT \* FROM ([^)]+)\)\s*', ''
    $content = $content -replace 'IF\s+EXISTS \(SELECT \* FROM ([^)]+)\)\s*', 'DELETE FROM $1; '
    $content = $content -replace 'DROP VIEW IF EXISTS "SchedulerManagerView"', 'DROP VIEW IF EXISTS "SchedulerManagerView"'

    if ($content -ne $original) {
        Set-Content -Path $file.FullName -Value $content -Encoding UTF8 -NoNewline
        Write-Host "Updated $($file.Name)"
    }
}

Write-Host "Seed SQL conversion complete."
