# One-time helper: convert EF migration files from SQL Server to PostgreSQL annotations/types.
$root = Join-Path $PSScriptRoot "..\..\src\DataAccess\Migrations"
$files = Get-ChildItem -Path $root -Filter "*.cs" -Recurse | Where-Object { $_.FullName -notmatch "\\Custom\\" }

$usingLine = "using Npgsql.EntityFrameworkCore.PostgreSQL.Metadata;"
$annotation = '.Annotation("Npgsql:ValueGenerationStrategy", NpgsqlValueGenerationStrategy.IdentityByDefaultColumn)'

foreach ($file in $files) {
    $content = Get-Content -Path $file.FullName -Raw -Encoding UTF8
    $original = $content

    if ($content -match 'SqlServer:Identity' -and $content -notmatch 'Npgsql\.EntityFrameworkCore') {
        $content = $usingLine + "`r`n" + $content
    }

    $content = $content -replace '\.Annotation\("SqlServer:Identity", "1, 1"\)', $annotation
    $content = $content -replace 'type: "nvarchar\(([^"]+)\)"', 'type: "character varying($1)"'
    $content = $content -replace 'type: "nvarchar\(max\)"', 'type: "text"'
    $content = $content -replace 'type: "varchar\(([^"]+)\)"', 'type: "character varying($1)"'
    $content = $content -replace 'type: "varchar\(max\)"', 'type: "text"'
    $content = $content -replace 'type: "datetime2"', 'type: "timestamp without time zone"'
    $content = $content -replace 'type: "datetime"', 'type: "timestamp without time zone"'
    $content = $content -replace 'type: "bit"', 'type: "boolean"'
    $content = $content -replace 'type: "float"', 'type: "double precision"'
    $content = $content -replace 'type: "uniqueidentifier"', 'type: "uuid"'
    $content = $content -replace 'type: "decimal\(([^"]+)\)"', 'type: "decimal($1)"'

    if ($content -ne $original) {
        Set-Content -Path $file.FullName -Value $content -Encoding UTF8 -NoNewline
        Write-Host "Updated $($file.Name)"
    }
}

Write-Host "Migration conversion complete."
