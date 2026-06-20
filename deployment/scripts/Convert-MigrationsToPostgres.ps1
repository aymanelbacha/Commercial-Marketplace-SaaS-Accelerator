# Converts EF migration files from SQL Server to PostgreSQL annotations/types.
$root = Join-Path $PSScriptRoot "..\..\src\DataAccess\Migrations"
$files = Get-ChildItem -Path $root -Filter "*.cs" -Recurse | Where-Object { $_.FullName -notmatch "\\Custom\\" }

$usingLine = "using Npgsql.EntityFrameworkCore.PostgreSQL.Metadata;"
$annotation = '.Annotation("Npgsql:ValueGenerationStrategy", NpgsqlValueGenerationStrategy.IdentityByDefaultColumn)'

foreach ($file in $files) {
    $content = Get-Content -Path $file.FullName -Raw -Encoding UTF8
    $original = $content

    if (($content -match 'SqlServer' -or $content -match 'SqlServer:Identity') -and $content -notmatch 'Npgsql\.EntityFrameworkCore') {
        if ($content -match '(?m)^using Microsoft\.EntityFrameworkCore\.Metadata;') {
            $content = $content -replace '(?m)^using Microsoft\.EntityFrameworkCore\.Metadata;', "using Microsoft.EntityFrameworkCore.Metadata;`r`n$usingLine"
        } else {
            $content = $content -replace '(?m)^using Microsoft\.EntityFrameworkCore;', "using Microsoft.EntityFrameworkCore;`r`n$usingLine"
        }
    }

    $content = $content -replace 'SqlServerModelBuilderExtensions\.UseIdentityColumns\(modelBuilder, 1L, 1\);', 'NpgsqlModelBuilderExtensions.UseIdentityByDefaultColumns(modelBuilder);'
    $content = $content -replace 'SqlServerPropertyBuilderExtensions\.UseIdentityColumn\(([^,]+), 1L, 1\);', 'NpgsqlPropertyBuilderExtensions.UseIdentityByDefaultColumn($1);'
    $content = $content -replace '\.Annotation\("SqlServer:Identity", "1, 1"\)', $annotation
    $content = $content -replace 'HasAnnotation\("Relational:MaxIdentifierLength", 128\)', 'HasAnnotation("Relational:MaxIdentifierLength", 63)'
    $content = $content -replace 'type: "nvarchar\(([^"]+)\)"', 'type: "character varying($1)"'
    $content = $content -replace 'type: "nvarchar\(max\)"', 'type: "text"'
    $content = $content -replace 'type: "varchar\(([^"]+)\)"', 'type: "character varying($1)"'
    $content = $content -replace 'type: "varchar\(max\)"', 'type: "text"'
    $content = $content -replace 'type: "datetime2"', 'type: "timestamp without time zone"'
    $content = $content -replace 'type: "datetime"', 'type: "timestamp without time zone"'
    $content = $content -replace 'type: "bit"', 'type: "boolean"'
    $content = $content -replace 'type: "float"', 'type: "double precision"'
    $content = $content -replace 'type: "uniqueidentifier"', 'type: "uuid"'
    $content = $content -replace 'type: "character varying\(max\)"', 'type: "text"'
    $content = $content -replace '\.HasColumnType\("nvarchar\(max\)"\)', '.HasColumnType("text")'
    $content = $content -replace '\.HasColumnType\("nvarchar\(([^"]+)\)"\)', '.HasColumnType("character varying($1)")'
    $content = $content -replace '\.HasColumnType\("varchar\(max\)"\)', '.HasColumnType("text")'
    $content = $content -replace '\.HasColumnType\("varchar\(([^"]+)\)"\)', '.HasColumnType("character varying($1)")'
    $content = $content -replace '\.HasColumnType\("datetime2"\)', '.HasColumnType("timestamp without time zone")'
    $content = $content -replace '\.HasColumnType\("datetime"\)', '.HasColumnType("timestamp without time zone")'
    $content = $content -replace '\.HasColumnType\("bit"\)', '.HasColumnType("boolean")'
    $content = $content -replace '\.HasColumnType\("float"\)', '.HasColumnType("double precision")'
    $content = $content -replace '\.HasColumnType\("uniqueidentifier"\)', '.HasColumnType("uuid")'

    if ($content -ne $original) {
        Set-Content -Path $file.FullName -Value $content -Encoding UTF8 -NoNewline
        Write-Host "Updated $($file.Name)"
    }
}

Write-Host "Migration conversion complete."
