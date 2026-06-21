#!/usr/bin/env bash
# Verify PostgreSQL 16 private VM setup for SaaS Accelerator.
# Run in Azure Cloud Shell (bash):
#   bash Verify-PostgresSetup.sh <WebAppNamePrefix> [ResourceGroup] [DatabaseName]
#
# Example:
#   bash Verify-PostgresSetup.sh amp_saas_accelerator_mydemo

set -euo pipefail

PREFIX="${1:-}"
RG="${2:-}"
DB_NAME="${3:-}"

if [[ -z "$PREFIX" ]]; then
  echo "Usage: $0 <WebAppNamePrefix> [ResourceGroup] [DatabaseName]"
  echo "Example: $0 amp_saas_accelerator_mydemo"
  exit 1
fi

[[ -z "$RG" ]] && RG="$PREFIX"
[[ -z "$DB_NAME" ]] && DB_NAME="${PREFIX}AMPSaaSDB"

VM="${PREFIX}-pgvm"
KV="${PREFIX}-kv"
ADMIN_APP="${PREFIX}-admin"
PORTAL_APP="${PREFIX}-portal"
PG_USER="saasadmin"
VNET_CIDR="10.0.0.0/20"

PASS=0
FAIL=0
WARN=0

green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }

pass() { PASS=$((PASS + 1)); green "  PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); red   "  FAIL: $*"; }
warn() { WARN=$((WARN + 1)); yellow "  WARN: $*"; }

section() { echo; echo "== $* =="; }

run_vm_script() {
  local script_b64
  script_b64=$(printf '%s' "$1" | base64 -w 0 2>/dev/null || printf '%s' "$1" | base64)
  az vm run-command invoke \
    --resource-group "$RG" \
    --name "$VM" \
    --command-id RunShellScript \
    --scripts "echo '$script_b64' | base64 -d | bash" \
    --output json 2>/dev/null | jq -r '.value[0].message // .value[0].Message // empty'
}

echo "SaaS Accelerator PostgreSQL verification"
echo "  Prefix:   $PREFIX"
echo "  RG:       $RG"
echo "  VM:       $VM"
echo "  Database: $DB_NAME"
echo "  KeyVault: $KV"
SUB=$(az account show --query name -o tsv 2>/dev/null || echo "unknown")
echo "  Subscription: $SUB"

section "1. VM and network"
if az vm show -g "$RG" -n "$VM" &>/dev/null; then
  pass "VM '$VM' exists in '$RG'"
else
  fail "VM '$VM' not found in '$RG'"
  echo; red "Cannot continue without the VM."; exit 1
fi

PRIVATE_IP=$(az vm list-ip-addresses -g "$RG" -n "$VM" \
  --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv 2>/dev/null || true)
PUBLIC_IP=$(az vm list-ip-addresses -g "$RG" -n "$VM" \
  --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" -o tsv 2>/dev/null || true)

if [[ -n "$PRIVATE_IP" && "$PRIVATE_IP" != "None" ]]; then
  pass "Private IP: $PRIVATE_IP"
else
  fail "No private IP assigned"
fi

if [[ -z "$PUBLIC_IP" || "$PUBLIC_IP" == "None" ]]; then
  pass "No public IP (private-only VM)"
else
  warn "Public IP present: $PUBLIC_IP (expected private-only)"
fi

VM_STATE=$(az vm get-instance-view -g "$RG" -n "$VM" \
  --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" -o tsv 2>/dev/null || true)
if [[ "$VM_STATE" == *"running"* ]]; then
  pass "VM power state: $VM_STATE"
else
  fail "VM not running: ${VM_STATE:-unknown}"
fi

section "2. Key Vault secrets"
if az keyvault show -n "$KV" -g "$RG" &>/dev/null; then
  pass "Key Vault '$KV' exists"
else
  fail "Key Vault '$KV' not found"
fi

PGPASS=""
CONN=""
if az keyvault secret show --vault-name "$KV" --name PostgresAdminPassword &>/dev/null; then
  PGPASS=$(az keyvault secret show --vault-name "$KV" --name PostgresAdminPassword --query value -o tsv)
  pass "Secret PostgresAdminPassword exists"
else
  fail "Secret PostgresAdminPassword missing"
fi

if az keyvault secret show --vault-name "$KV" --name DefaultConnection &>/dev/null; then
  CONN=$(az keyvault secret show --vault-name "$KV" --name DefaultConnection --query value -o tsv)
  pass "Secret DefaultConnection exists"
  if [[ "$CONN" == *"Host=$PRIVATE_IP"* ]]; then
    pass "DefaultConnection Host matches VM private IP"
  else
    warn "DefaultConnection Host may not match current private IP ($PRIVATE_IP)"
  fi
  if [[ "$CONN" == *"Database=$DB_NAME"* ]]; then
    pass "DefaultConnection Database name matches"
  else
    warn "DefaultConnection Database name may differ from '$DB_NAME'"
  fi
else
  fail "Secret DefaultConnection missing"
fi

section "3. PostgreSQL service (via Run Command)"
if [[ -z "$PGPASS" ]]; then
  fail "Skipping DB checks — no PostgresAdminPassword"
else
  SVC_OUT=$(run_vm_script "set -e
systemctl is-active postgresql
psql --version | head -1
ss -lntp 2>/dev/null | grep ':5432' || netstat -lntp 2>/dev/null | grep ':5432' || true
cloud-init status 2>/dev/null || true" || true)

  echo "$SVC_OUT" | sed 's/^/    /'

  if echo "$SVC_OUT" | grep -q "active"; then
    pass "postgresql service is active"
  else
    fail "postgresql service not active"
  fi

  if echo "$SVC_OUT" | grep -qi "postgresql 16"; then
    pass "PostgreSQL 16 installed"
  elif echo "$SVC_OUT" | grep -qi "psql"; then
    warn "psql found but version may not be 16"
  else
    fail "psql / PostgreSQL not found"
  fi

  if echo "$SVC_OUT" | grep -q ":5432"; then
    pass "Port 5432 is listening"
  else
    fail "Port 5432 not listening"
  fi

  if echo "$SVC_OUT" | grep -qi "status: done"; then
    pass "cloud-init finished"
  elif echo "$SVC_OUT" | grep -qi "running"; then
    warn "cloud-init still running — wait and re-check"
  else
    warn "cloud-init status unclear"
  fi
fi

if [[ -n "$PGPASS" ]]; then
  ESCAPED_PASS=${PGPASS//\'/\'\\\'\'}
fi

section "4. Database, user, extension"
if [[ -n "$PGPASS" ]]; then
  DB_OUT=$(run_vm_script "set -e
export PGPASSWORD='${ESCAPED_PASS}'
psql -h 127.0.0.1 -U ${PG_USER} -d \"${DB_NAME}\" -v ON_ERROR_STOP=1 -tAc \"SELECT version();\"
psql -h 127.0.0.1 -U ${PG_USER} -d \"${DB_NAME}\" -tAc \"SELECT current_database() || ' / ' || current_user;\"
psql -h 127.0.0.1 -U ${PG_USER} -d \"${DB_NAME}\" -tAc \"SELECT extname FROM pg_extension WHERE extname='pgcrypto';\"" || true)

  echo "$DB_OUT" | sed 's/^/    /'

  if echo "$DB_OUT" | grep -qi "postgresql 16"; then
    pass "Connected to database; PostgreSQL 16"
  elif echo "$DB_OUT" | grep -qi "postgresql"; then
    pass "Connected to database"
  else
    fail "Cannot connect to database '$DB_NAME' as '$PG_USER'"
  fi

  if echo "$DB_OUT" | grep -q "pgcrypto"; then
    pass "Extension pgcrypto installed"
  else
    fail "Extension pgcrypto missing"
  fi
fi

section "5. EF migrations and schema"
EXPECTED_MIGRATIONS=(
  "20221118045814_Baseline_v2"
  "20221118203340_Baseline_v5"
  "20221118211554_Baseline_v6"
  "20230726232155_Baseline_v7"
  "20230912052848_SubscriptionDetails_v740"
  "20231115232155_Baseline_v741"
  "20240312055030_baseline751"
)

if [[ -n "$PGPASS" ]]; then
  MIG_OUT=$(run_vm_script "set -e
export PGPASSWORD='${ESCAPED_PASS}'
HIST=\$(psql -h 127.0.0.1 -U ${PG_USER} -d \"${DB_NAME}\" -tAc \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='__EFMigrationsHistory';\")
TABLES=\$(psql -h 127.0.0.1 -U ${PG_USER} -d \"${DB_NAME}\" -tAc \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';\")
SEED=\$(psql -h 127.0.0.1 -U ${PG_USER} -d \"${DB_NAME}\" -tAc \"SELECT COUNT(*) FROM \\\"ApplicationConfiguration\\\";\")
echo \"HIST=\$HIST\"
echo \"TABLES=\$TABLES\"
echo \"SEED=\$SEED\"
psql -h 127.0.0.1 -U ${PG_USER} -d \"${DB_NAME}\" -tAc \"SELECT \\\"MigrationId\\\" FROM \\\"__EFMigrationsHistory\\\" ORDER BY \\\"MigrationId\\\";\"" || true)

  echo "$MIG_OUT" | sed 's/^/    /'

  HIST_COUNT=$(echo "$MIG_OUT" | grep '^HIST=' | cut -d= -f2 | tr -d '[:space:]')
  TABLE_COUNT=$(echo "$MIG_OUT" | grep '^TABLES=' | cut -d= -f2 | tr -d '[:space:]')
  SEED_COUNT=$(echo "$MIG_OUT" | grep '^SEED=' | cut -d= -f2 | tr -d '[:space:]')

  if [[ "$HIST_COUNT" == "1" ]]; then
    pass "__EFMigrationsHistory table exists"
  else
    fail "__EFMigrationsHistory table missing — migrations not applied"
  fi

  for mig in "${EXPECTED_MIGRATIONS[@]}"; do
    if echo "$MIG_OUT" | grep -q "$mig"; then
      pass "Migration $mig"
    else
      fail "Migration $mig missing"
    fi
  done

  if [[ -n "$TABLE_COUNT" && "$TABLE_COUNT" -ge 10 ]]; then
    pass "Public tables: $TABLE_COUNT"
  elif [[ -n "$TABLE_COUNT" && "$TABLE_COUNT" -gt 0 ]]; then
    warn "Only $TABLE_COUNT public tables (expected many more after full migrate)"
  else
    fail "Could not count public tables"
  fi

  if [[ -n "$SEED_COUNT" && "$SEED_COUNT" -gt 0 ]]; then
    pass "ApplicationConfiguration seed rows: $SEED_COUNT"
  else
    fail "ApplicationConfiguration has no seed data"
  fi
fi

section "6. PostgreSQL functions (sp_get_*)"
EXPECTED_FUNCS=(
  "sp_get_subscription_parameters"
  "sp_get_plan_events"
  "sp_get_offer_parameters"
  "sp_get_formatted_email_body"
)

if [[ -n "$PGPASS" ]]; then
  FUNC_OUT=$(run_vm_script "set -e
export PGPASSWORD='${ESCAPED_PASS}'
psql -h 127.0.0.1 -U ${PG_USER} -d \"${DB_NAME}\" -tAc \"SELECT proname FROM pg_proc p JOIN pg_namespace n ON p.pronamespace=n.oid WHERE n.nspname='public' AND proname LIKE 'sp_get_%' ORDER BY proname;\"" || true)

  echo "$FUNC_OUT" | sed 's/^/    /'

  for fn in "${EXPECTED_FUNCS[@]}"; do
    if echo "$FUNC_OUT" | grep -q "$fn"; then
      pass "Function $fn"
    else
      fail "Function $fn missing"
    fi
  done
fi

section "7. PostgreSQL network config"
CFG_OUT=$(run_vm_script "grep -E \"^listen_addresses|^ssl\" /etc/postgresql/16/main/postgresql.conf 2>/dev/null | head -5; grep '${VNET_CIDR}' /etc/postgresql/16/main/pg_hba.conf 2>/dev/null || true" || true)
echo "$CFG_OUT" | sed 's/^/    /'

if echo "$CFG_OUT" | grep -q "listen_addresses.*'\*'"; then
  pass "listen_addresses = '*'"
else
  warn "listen_addresses may not allow remote connections"
fi

if echo "$CFG_OUT" | grep -q "$VNET_CIDR"; then
  pass "pg_hba allows VNet $VNET_CIDR"
else
  fail "pg_hba missing rule for $VNET_CIDR"
fi

section "8. App Service connection strings and VNet integration"
for APP in "$ADMIN_APP" "$PORTAL_APP"; do
  if az webapp show -g "$RG" -n "$APP" &>/dev/null; then
    pass "Web app '$APP' exists"
    CS=$(az webapp config connection-string list -g "$RG" -n "$APP" \
      --query "[?name=='DefaultConnection'].{type:type,value:value}" -o tsv 2>/dev/null || true)
    if echo "$CS" | grep -qi "PostgreSQL\|postgres"; then
      pass "$APP DefaultConnection type is PostgreSQL"
    elif [[ -n "$CS" ]]; then
      warn "$APP DefaultConnection exists but type may not be PostgreSQL"
    else
      fail "$APP DefaultConnection not configured"
    fi
    VNI=$(az webapp vnet-integration list -g "$RG" -n "$APP" -o tsv 2>/dev/null || true)
    if [[ -n "$VNI" ]]; then
      pass "$APP VNet integrated"
    else
      fail "$APP not VNet integrated (cannot reach private PostgreSQL)"
    fi
  else
    warn "Web app '$APP' not found (deploy may be incomplete)"
  fi
done

section "Summary"
echo "  Passed:   $PASS"
echo "  Failed:   $FAIL"
echo "  Warnings: $WARN"
echo

if [[ "$FAIL" -eq 0 ]]; then
  green "All critical checks passed. PostgreSQL looks ready for the SaaS Accelerator."
  exit 0
else
  red "$FAIL check(s) failed. Review output above."
  exit 1
fi
