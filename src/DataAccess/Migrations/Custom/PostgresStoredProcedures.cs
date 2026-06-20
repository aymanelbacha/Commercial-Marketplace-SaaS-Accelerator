using Microsoft.EntityFrameworkCore.Migrations;

namespace Marketplace.SaaS.Accelerator.DataAccess.Migrations.Custom;

internal static class PostgresStoredProcedures
{
    public static void Seed(this MigrationBuilder migrationBuilder)
    {
        migrationBuilder.Sql("DROP FUNCTION IF EXISTS sp_get_subscription_parameters(uuid, uuid);");
        migrationBuilder.Sql("DROP FUNCTION IF EXISTS sp_get_plan_events(uuid);");
        migrationBuilder.Sql("DROP FUNCTION IF EXISTS sp_get_offer_parameters(uuid);");
        migrationBuilder.Sql("DROP FUNCTION IF EXISTS sp_get_formatted_email_body(text, text);");

        migrationBuilder.Sql(@"
CREATE OR REPLACE FUNCTION sp_get_subscription_parameters(p_subscription_id uuid, p_plan_id uuid)
RETURNS TABLE (
    ""RowNumber"" integer,
    ""Id"" integer,
    ""PlanAttributeId"" integer,
    ""PlanId"" uuid,
    ""OfferAttributeId"" integer,
    ""DisplayName"" character varying,
    ""Type"" character varying,
    ""ValueType"" character varying,
    ""DisplaySequence"" integer,
    ""IsEnabled"" boolean,
    ""IsRequired"" boolean,
    ""Value"" character varying,
    ""SubscriptionId"" uuid,
    ""OfferId"" uuid,
    ""UserId"" integer,
    ""CreateDate"" timestamp without time zone,
    ""FromList"" boolean,
    ""ValuesList"" character varying,
    ""Max"" integer,
    ""Min"" integer,
    ""HTMLType"" character varying
) AS $$
DECLARE
    v_offer_id uuid;
BEGIN
    SELECT ""OfferId"" INTO v_offer_id FROM ""Plans"" WHERE ""PlanGUID"" = p_plan_id;

    RETURN QUERY
    SELECT
        CAST(ROW_NUMBER() OVER (ORDER BY oa.""ID"") AS integer) AS ""RowNumber"",
        COALESCE(sav.""ID"", 0) AS ""Id"",
        COALESCE(sav.""PlanAttributeId"", pa.""PlanAttributeId"") AS ""PlanAttributeId"",
        COALESCE(sav.""PlanId"", p_plan_id) AS ""PlanId"",
        COALESCE(pa.""OfferAttributeID"", oa.""ID"") AS ""OfferAttributeId"",
        COALESCE(oa.""DisplayName"", '') AS ""DisplayName"",
        COALESCE(oa.""Type"", '') AS ""Type"",
        COALESCE(vt.""ValueType"", '') AS ""ValueType"",
        COALESCE(oa.""DisplaySequence"", 0) AS ""DisplaySequence"",
        COALESCE(pa.""IsEnabled"", false) AS ""IsEnabled"",
        COALESCE(oa.""IsRequired"", false) AS ""IsRequired"",
        COALESCE(sav.""Value"", '') AS ""Value"",
        COALESCE(sav.""SubscriptionId"", p_subscription_id) AS ""SubscriptionId"",
        COALESCE(sav.""OfferID"", oa.""OfferId"") AS ""OfferId"",
        sav.""UserId"",
        sav.""CreateDate"",
        COALESCE(oa.""FromList"", false) AS ""FromList"",
        COALESCE(oa.""ValuesList"", '') AS ""ValuesList"",
        COALESCE(oa.""Max"", 0) AS ""Max"",
        COALESCE(oa.""Min"", 0) AS ""Min"",
        COALESCE(vt.""HTMLType"", '') AS ""HTMLType""
    FROM ""OfferAttributes"" oa
    INNER JOIN ""PlanAttributeMapping"" pa ON oa.""ID"" = pa.""OfferAttributeID"" AND oa.""OfferId"" = v_offer_id AND pa.""PlanId"" = p_plan_id
    LEFT JOIN ""SubscriptionAttributeValues"" sav ON sav.""PlanAttributeId"" = pa.""PlanAttributeId"" AND sav.""SubscriptionId"" = p_subscription_id
    INNER JOIN ""ValueTypes"" vt ON oa.""ValueTypeId"" = vt.""ValueTypeId""
    WHERE oa.""Isactive"" = true AND pa.""IsEnabled"" = true;
END;
$$ LANGUAGE plpgsql;");

        migrationBuilder.Sql(@"
CREATE OR REPLACE FUNCTION sp_get_plan_events(p_plan_id uuid)
RETURNS TABLE (
    ""RowNumber"" integer,
    ""Id"" integer,
    ""PlanId"" uuid,
    ""Isactive"" boolean,
    ""CopyToCustomer"" boolean,
    ""SuccessStateEmails"" character varying,
    ""FailureStateEmails"" character varying,
    ""EventId"" integer,
    ""EventsName"" character varying
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        CAST(ROW_NUMBER() OVER (ORDER BY e.""EventsId"") AS integer) AS ""RowNumber"",
        COALESCE(oem.""Id"", 0) AS ""Id"",
        COALESCE(oem.""PlanId"", p_plan_id) AS ""PlanId"",
        COALESCE(oem.""Isactive"", false) AS ""Isactive"",
        COALESCE(oem.""CopyToCustomer"", false) AS ""CopyToCustomer"",
        COALESCE(oem.""SuccessStateEmails"", '') AS ""SuccessStateEmails"",
        COALESCE(oem.""FailureStateEmails"", '') AS ""FailureStateEmails"",
        e.""EventsId"" AS ""EventId"",
        e.""EventsName""
    FROM ""Events"" e
    LEFT JOIN ""PlanEventsMapping"" oem ON e.""EventsId"" = oem.""EventId"" AND oem.""PlanId"" = p_plan_id
    WHERE e.""Isactive"" = true;
END;
$$ LANGUAGE plpgsql;");

        migrationBuilder.Sql(@"
CREATE OR REPLACE FUNCTION sp_get_offer_parameters(p_plan_id uuid)
RETURNS TABLE (
    ""RowNumber"" integer,
    ""PlanAttributeId"" integer,
    ""PlanId"" uuid,
    ""OfferAttributeId"" integer,
    ""DisplayName"" character varying,
    ""IsEnabled"" boolean,
    ""Type"" character varying
) AS $$
DECLARE
    v_offer_id uuid;
BEGIN
    SELECT ""OfferId"" INTO v_offer_id FROM ""Plans"" WHERE ""PlanGUID"" = p_plan_id;

    RETURN QUERY
    SELECT
        CAST(ROW_NUMBER() OVER (ORDER BY oa.""ID"") AS integer) AS ""RowNumber"",
        COALESCE(pa.""PlanAttributeId"", 0) AS ""PlanAttributeId"",
        COALESCE(pa.""PlanId"", p_plan_id) AS ""PlanId"",
        COALESCE(pa.""OfferAttributeID"", oa.""ID"") AS ""OfferAttributeId"",
        oa.""DisplayName"",
        COALESCE(pa.""IsEnabled"", false) AS ""IsEnabled"",
        oa.""Type""
    FROM ""OfferAttributes"" oa
    LEFT JOIN ""PlanAttributeMapping"" pa ON oa.""ID"" = pa.""OfferAttributeID"" AND oa.""OfferId"" = v_offer_id AND pa.""PlanId"" = p_plan_id
    WHERE oa.""Isactive"" = true;
END;
$$ LANGUAGE plpgsql;");

        migrationBuilder.Sql(@"
CREATE OR REPLACE FUNCTION sp_get_formatted_email_body(p_subscription_id text, p_process_status text)
RETURNS TABLE (""Id"" integer, ""Name"" text, ""Value"" text) AS $$
DECLARE
    v_plan_id text;
    v_plan_guid uuid;
    v_plan_name text;
    v_offer_guid uuid;
    v_offer_id text;
    v_offer_name text;
    v_subscription_status text;
    v_subscription_name text;
    v_purchaser_email text;
    v_purchaser_tenant text;
    v_user_id integer;
    v_customer_name text;
    v_customer_email text;
    v_application_name text;
    v_welcome_text text := '';
    v_html text;
    v_subscription_content text := '';
    v_row record;
BEGIN
    SELECT ""Value"" INTO v_application_name FROM ""ApplicationConfiguration"" WHERE ""Name"" = 'ApplicationName';

    IF EXISTS (SELECT 1 FROM ""Subscriptions"" WHERE ""AMPSubscriptionId""::text = p_subscription_id) THEN
        SELECT ""AMPPLanId"", ""subscriptionstatus"", ""Name"", ""PurchaserEmail"", ""PurchaserTenantId"", ""UserId""
        INTO v_plan_id, v_subscription_status, v_subscription_name, v_purchaser_email, v_purchaser_tenant, v_user_id
        FROM ""Subscriptions"" WHERE ""AMPSubscriptionId""::text = p_subscription_id;

        SELECT ""FullName"", ""EmailAddress"" INTO v_customer_name, v_customer_email
        FROM ""Users"" WHERE ""UserId"" = v_user_id;

        IF EXISTS (SELECT 1 FROM ""Plans"" WHERE ""PlanId"" = v_plan_id) THEN
            SELECT ""OfferId"", ""DisplayName"", ""PlanGUID"" INTO v_offer_guid, v_plan_name, v_plan_guid
            FROM ""Plans"" WHERE ""PlanId"" = v_plan_id;

            IF EXISTS (SELECT 1 FROM ""Offers"" WHERE ""OfferGUId"" = v_offer_guid) THEN
                SELECT ""OfferId"", ""OfferName"" INTO v_offer_id, v_offer_name
                FROM ""Offers"" WHERE ""OfferGUId"" = v_offer_guid;
            END IF;
        END IF;
    END IF;

    CREATE TEMP TABLE tmp_email_labels (""HtmlLabel"" text, ""HtmlValue"" text) ON COMMIT DROP;
    INSERT INTO tmp_email_labels VALUES
        ('Customer Email Address', COALESCE(v_customer_email, '')),
        ('Customer Name', COALESCE(v_customer_name, '')),
        ('SaaS Subscription Id', p_subscription_id),
        ('SaaS Subscription Name', COALESCE(v_subscription_name, '')),
        ('SaaS Subscription Status', COALESCE(v_subscription_status, '')),
        ('Plan', COALESCE(v_plan_name, '')),
        ('Purchaser Email Address', COALESCE(v_customer_email, '')),
        ('Purchaser Tenant', COALESCE(v_purchaser_tenant, ''));

    INSERT INTO tmp_email_labels
    SELECT COALESCE(oa.""DisplayName"", ''), COALESCE(sav.""Value"", '')
    FROM ""OfferAttributes"" oa
    INNER JOIN ""PlanAttributeMapping"" pa ON oa.""ID"" = pa.""OfferAttributeID"" AND oa.""OfferId"" = v_offer_guid AND pa.""PlanId"" = v_plan_guid
    INNER JOIN ""SubscriptionAttributeValues"" sav ON sav.""PlanAttributeId"" = pa.""PlanAttributeId"" AND sav.""SubscriptionId""::text = p_subscription_id
    WHERE oa.""Isactive"" = true AND pa.""IsEnabled"" = true;

    FOR v_row IN SELECT * FROM tmp_email_labels LOOP
        v_subscription_content := v_subscription_content || '<tr><td><b>' || v_row.""HtmlLabel"" || '</b></td><td>' || v_row.""HtmlValue"" || '</td></tr>';
    END LOOP;

    IF lower(p_process_status) = 'failure' THEN
        v_welcome_text := 'Your request for the subscription has been failed.';
        SELECT ""TemplateBody"" INTO v_html FROM ""EmailTemplate"" WHERE ""Status"" = 'Failed';
    END IF;

    IF lower(p_process_status) = 'success' THEN
        IF v_subscription_status = 'PendingActivation' THEN
            v_welcome_text := 'A request for purchase with the following details is awaiting your action for activation.';
        ELSIF v_subscription_status = 'Subscribed' THEN
            v_welcome_text := 'Your request for the purchase has been approved.';
        ELSIF v_subscription_status = 'Unsubscribed' THEN
            v_welcome_text := 'A subscription with the following details was deleted from Azure.';
        END IF;
        SELECT ""TemplateBody"" INTO v_html FROM ""EmailTemplate"" WHERE ""Status"" = v_subscription_status;
    END IF;

    v_html := replace(v_html, '${subscriptiondetails}', v_subscription_content);
    v_html := replace(v_html, '${welcometext}', v_welcome_text);
    v_html := replace(v_html, '${ApplicationName}', COALESCE(v_application_name, ''));

    RETURN QUERY SELECT 1 AS ""Id"", 'Email'::text AS ""Name"", v_html AS ""Value"";
END;
$$ LANGUAGE plpgsql;");
    }

    public static void Drop(this MigrationBuilder migrationBuilder)
    {
        migrationBuilder.Sql("DROP FUNCTION IF EXISTS sp_get_subscription_parameters(uuid, uuid);");
        migrationBuilder.Sql("DROP FUNCTION IF EXISTS sp_get_plan_events(uuid);");
        migrationBuilder.Sql("DROP FUNCTION IF EXISTS sp_get_offer_parameters(uuid);");
        migrationBuilder.Sql("DROP FUNCTION IF EXISTS sp_get_formatted_email_body(text, text);");
    }
}
