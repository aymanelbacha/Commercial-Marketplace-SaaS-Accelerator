using Microsoft.EntityFrameworkCore.Migrations;
using Microsoft.EntityFrameworkCore.Query.Internal;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace Marketplace.SaaS.Accelerator.DataAccess.Migrations.Custom
{
    internal static class BaselineV5_Seed
    {
        public static void BaselineV5_SeedData(this MigrationBuilder migrationBuilder)
        {
            var seedDate = DateTime.Now;
            migrationBuilder.Sql(@$"
INSERT INTO ""SchedulerFrequency"" (""Frequency"") VALUES ('Hourly');
INSERT INTO ""SchedulerFrequency"" (""Frequency"") VALUES ('Daily');
INSERT INTO ""SchedulerFrequency"" (""Frequency"") VALUES ('Weekly');
INSERT INTO ""SchedulerFrequency"" (""Frequency"") VALUES ('Monthly');
INSERT INTO ""SchedulerFrequency"" (""Frequency"") VALUES ('Yearly');
");
        }

        public static void BaselineV5_SeedViews(this MigrationBuilder migrationBuilder)
        {
            migrationBuilder.Sql(@"
CREATE OR REPLACE VIEW ""SchedulerManagerView"" AS
SELECT
    m.""Id"",
    m.""SchedulerName"",
    s.""AMPSubscriptionId"",
    s.""Name"" AS ""SubscriptionName"",
    s.""PurchaserEmail"",
    p.""PlanId"",
    d.""Dimension"",
    f.""Frequency"",
    m.""Quantity"",
    m.""StartDate"",
    m.""NextRunTime""
FROM ""MeteredPlanSchedulerManagement"" m
INNER JOIN ""SchedulerFrequency"" f ON m.""FrequencyId"" = f.""Id""
INNER JOIN ""Subscriptions"" s ON m.""SubscriptionId"" = s.""Id""
INNER JOIN ""Plans"" p ON m.""PlanId"" = p.""Id""
INNER JOIN ""MeteredDimensions"" d ON m.""DimensionId"" = d.""Id"";
");
        }

        public static void BaselineV5_DeSeedAll(this MigrationBuilder migrationBuilder)
        {
            migrationBuilder.Sql(@"DROP VIEW IF EXISTS ""SchedulerManagerView"";");
        }
    }
}