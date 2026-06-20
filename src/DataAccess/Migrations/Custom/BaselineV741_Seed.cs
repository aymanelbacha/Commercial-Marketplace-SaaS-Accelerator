using Microsoft.EntityFrameworkCore.Migrations;

namespace Marketplace.SaaS.Accelerator.DataAccess.Migrations.Custom;

internal static class BaselineV741_Seed
{
    public static void BaselineV741_SeedData(this MigrationBuilder migrationBuilder)
    {
        migrationBuilder.Sql(@"
INSERT INTO ""ApplicationConfiguration"" (""Name"", ""Value"", ""Description"")
SELECT 'IsMeteredBillingEnabled', 'true', 'Enable Metered Billing Feature'
WHERE NOT EXISTS (SELECT 1 FROM ""ApplicationConfiguration"" WHERE ""Name"" = 'IsMeteredBillingEnabled');
");
    }

    public static void BaselineV741_DeSeedData(this MigrationBuilder migrationBuilder)
    {
        migrationBuilder.Sql(@"DELETE FROM ""ApplicationConfiguration"" WHERE ""Name"" = 'IsMeteredBillingEnabled';");
    }
}
