import re
import pathlib

root = pathlib.Path(__file__).resolve().parents[2] / "src" / "DataAccess" / "Migrations"
files = list(root.glob("*.Designer.cs")) + [root / "SaasKitContextModelSnapshot.cs"]

using_line = "using Npgsql.EntityFrameworkCore.PostgreSQL.Metadata;"

for path in files:
    text = path.read_text(encoding="utf-8")
    original = text

    if "SqlServer" in text and using_line not in text:
        text = re.sub(
            r"^using Microsoft\.EntityFrameworkCore\.Metadata;",
            f"using Microsoft.EntityFrameworkCore.Metadata;\n{using_line}",
            text,
            count=1,
            flags=re.M,
        )

    text = text.replace(
        "SqlServerModelBuilderExtensions.UseIdentityColumns(modelBuilder, 1L, 1);",
        "NpgsqlModelBuilderExtensions.UseIdentityByDefaultColumns(modelBuilder);",
    )
    text = re.sub(
        r"SqlServerPropertyBuilderExtensions\.UseIdentityColumn\(([^,]+), 1L, 1\);",
        r"NpgsqlPropertyBuilderExtensions.UseIdentityByDefaultColumn(\1);",
        text,
    )
    text = text.replace(
        'HasAnnotation("Relational:MaxIdentifierLength", 128)',
        'HasAnnotation("Relational:MaxIdentifierLength", 63)',
    )
    text = text.replace('.HasColumnType("nvarchar(max)")', '.HasColumnType("text")')
    text = re.sub(
        r'\.HasColumnType\("nvarchar\(([^"]+)\)"\)',
        r'.HasColumnType("character varying(\1)")',
        text,
    )
    text = text.replace(
        '.HasColumnType("datetime2")', '.HasColumnType("timestamp without time zone")'
    )
    text = text.replace(
        '.HasColumnType("datetime")', '.HasColumnType("timestamp without time zone")'
    )
    text = text.replace('.HasColumnType("bit")', '.HasColumnType("boolean")')
    text = text.replace('.HasColumnType("float")', '.HasColumnType("double precision")')
    text = text.replace('.HasColumnType("uniqueidentifier")', '.HasColumnType("uuid")')

    if text != original:
        path.write_text(text, encoding="utf-8", newline="\r\n")
        print(f"Updated {path.name}")

print("Done.")
