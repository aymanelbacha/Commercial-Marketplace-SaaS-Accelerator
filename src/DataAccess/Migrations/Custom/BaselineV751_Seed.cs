using Microsoft.EntityFrameworkCore.Migrations;

namespace Marketplace.SaaS.Accelerator.DataAccess.Migrations.Custom;

internal static class BaselineV751_Seed
{
    public static void BaselineV751_SeedData(this MigrationBuilder migrationBuilder)
    {
        migrationBuilder.Sql(@"
INSERT INTO ""ApplicationConfiguration"" (""Name"", ""Value"", ""Description"")
SELECT 'ValidateWebhookJwtToken', 'true', 'Validates JWT token when webhook event is recieved.'
WHERE NOT EXISTS (SELECT 1 FROM ""ApplicationConfiguration"" WHERE ""Name"" = 'ValidateWebhookJwtToken');
");
    }

    public static void BaselineV751_DeSeedData(this MigrationBuilder migrationBuilder)
    {
        migrationBuilder.Sql(@"DELETE FROM ""ApplicationConfiguration"" WHERE ""Name"" = 'ValidateWebhookJwtToken';");
    }
}
