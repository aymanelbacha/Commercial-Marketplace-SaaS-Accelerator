using Microsoft.EntityFrameworkCore.Migrations;

namespace Marketplace.SaaS.Accelerator.DataAccess.Migrations.Custom;

internal static class BaselineV7_Seed
{
    public static void BaselineV7_SeedData(this MigrationBuilder migrationBuilder)
    {
        migrationBuilder.Sql(@"
INSERT INTO ""ApplicationConfiguration"" (""Name"", ""Value"", ""Description"")
SELECT 'WebNotificationUrl', '', 'Setting this URL will enable pushing LandingPage/Webhook events to this external URL'
WHERE NOT EXISTS (SELECT 1 FROM ""ApplicationConfiguration"" WHERE ""Name"" = 'WebNotificationUrl');

INSERT INTO ""ApplicationConfiguration"" (""Name"", ""Value"", ""Description"")
SELECT 'EnablesSuccessfulSchedulerEmail', 'False', 'This will enable sending email for successful metered usage.'
WHERE NOT EXISTS (SELECT 1 FROM ""ApplicationConfiguration"" WHERE ""Name"" = 'EnablesSuccessfulSchedulerEmail');

INSERT INTO ""ApplicationConfiguration"" (""Name"", ""Value"", ""Description"")
SELECT 'EnablesFailureSchedulerEmail', 'False', 'This will enable sending email for failure metered usage.'
WHERE NOT EXISTS (SELECT 1 FROM ""ApplicationConfiguration"" WHERE ""Name"" = 'EnablesFailureSchedulerEmail');

INSERT INTO ""ApplicationConfiguration"" (""Name"", ""Value"", ""Description"")
SELECT 'EnablesMissingSchedulerEmail', 'False', 'This will enable sending email for missing metered usage.'
WHERE NOT EXISTS (SELECT 1 FROM ""ApplicationConfiguration"" WHERE ""Name"" = 'EnablesMissingSchedulerEmail');

INSERT INTO ""ApplicationConfiguration"" (""Name"", ""Value"", ""Description"")
SELECT 'SchedulerEmailTo', '', 'Scheduler email receiver(s)'
WHERE NOT EXISTS (SELECT 1 FROM ""ApplicationConfiguration"" WHERE ""Name"" = 'SchedulerEmailTo');
");
    }

    public static void BaselineV7_DeSeedData(this MigrationBuilder migrationBuilder)
    {
        migrationBuilder.Sql(@"
DELETE FROM ""ApplicationConfiguration"" WHERE ""Name"" = 'WebNotificationUrl';
DELETE FROM ""ApplicationConfiguration"" WHERE ""Name"" = 'EnablesSuccessfulSchedulerEmail';
DELETE FROM ""ApplicationConfiguration"" WHERE ""Name"" = 'EnablesFailureSchedulerEmail';
DELETE FROM ""ApplicationConfiguration"" WHERE ""Name"" = 'EnablesMissingSchedulerEmail';
DELETE FROM ""ApplicationConfiguration"" WHERE ""Name"" = 'SchedulerEmailTo';
");
    }
}
