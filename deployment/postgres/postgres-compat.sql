-- PostgreSQL compatibility shims for SQL Server migration scripts
CREATE OR REPLACE FUNCTION newid() RETURNS uuid
LANGUAGE sql STABLE
AS $$ SELECT gen_random_uuid(); $$;
