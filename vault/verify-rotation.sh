#!/bin/bash
# ============================================================
# Vault LDAP Static Role - Rotation Verification Script
#
# Usage:
#   export VAULT_ADDR="https://your-hcp-vault-cluster.hashicorp.cloud:8200"
#   export VAULT_TOKEN="hvs.xxxx"
#   export VAULT_NAMESPACE="admin"
#   ./verify-rotation.sh [mount_path] [role_name]
#
# Defaults: mount_path=ldap, role_name=service-account-1
# ============================================================

set -euo pipefail

MOUNT="${1:-ldap}"
ROLE="${2:-service-account-1}"

# ---- Preflight checks ----
if [[ -z "${VAULT_ADDR:-}" ]]; then
  echo "ERROR: VAULT_ADDR is not set."
  echo "       export VAULT_ADDR='https://your-vault-cluster:8200'"
  exit 1
fi

if [[ -z "${VAULT_TOKEN:-}" ]]; then
  echo "ERROR: VAULT_TOKEN is not set."
  echo "       export VAULT_TOKEN='hvs.xxxx'"
  exit 1
fi

VAULT_NAMESPACE="${VAULT_NAMESPACE:-admin}"

echo "============================================================"
echo " Vault LDAP Rotation Verification"
echo "============================================================"
echo " Vault Addr  : $VAULT_ADDR"
echo " Namespace   : $VAULT_NAMESPACE"
echo " Mount       : $MOUNT"
echo " Role        : $ROLE"
echo "============================================================"
echo ""

# ---- Step 1: Verify Vault is reachable ----
echo "==> [1/5] Checking Vault connectivity..."
vault status -namespace="$VAULT_NAMESPACE" > /dev/null 2>&1 \
  && echo "    OK: Vault is reachable." \
  || { echo "    FAIL: Cannot reach Vault at $VAULT_ADDR"; exit 1; }

# ---- Step 2: Verify LDAP mount exists ----
echo ""
echo "==> [2/5] Verifying LDAP secrets engine mount ($MOUNT)..."
if vault secrets list -namespace="$VAULT_NAMESPACE" -format=json | python3 -c "import sys,json; mounts=json.load(sys.stdin); exit(0 if '${MOUNT}/' in mounts else 1)" 2>/dev/null; then
  echo "    OK: Mount '${MOUNT}/' is enabled."
else
  echo "    FAIL: Mount '${MOUNT}/' not found. Has Terraform been applied?"
  echo "    Run: vault secrets list -namespace=$VAULT_NAMESPACE"
  exit 1
fi

# ---- Step 3: Read current credentials (before rotation) ----
echo ""
echo "==> [3/5] Reading current credentials for role '$ROLE'..."
CREDS_BEFORE=$(vault read -namespace="$VAULT_NAMESPACE" -format=json "${MOUNT}/static-cred/${ROLE}" 2>&1) || {
  echo "    FAIL: Could not read credentials."
  echo "    $CREDS_BEFORE"
  exit 1
}

PASS_BEFORE=$(echo "$CREDS_BEFORE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['password'])")
LAST_ROTATION=$(echo "$CREDS_BEFORE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'].get('last_vault_rotation','N/A'))")

echo "    Username      : $(echo "$CREDS_BEFORE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['username'])")"
echo "    Password      : ${PASS_BEFORE:0:6}****** (truncated)"
echo "    Last rotation : $LAST_ROTATION"
echo "    TTL           : $(echo "$CREDS_BEFORE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'].get('ttl','N/A'))") seconds"

# ---- Step 4: Manually trigger rotation ----
echo ""
echo "==> [4/5] Triggering manual rotation for role '$ROLE'..."
vault write -namespace="$VAULT_NAMESPACE" -f "${MOUNT}/rotate-role/${ROLE}" \
  && echo "    OK: Rotation triggered." \
  || { echo "    FAIL: Rotation command failed."; exit 1; }

sleep 2

# ---- Step 5: Read new credentials and confirm they changed ----
echo ""
echo "==> [5/5] Reading updated credentials..."
CREDS_AFTER=$(vault read -namespace="$VAULT_NAMESPACE" -format=json "${MOUNT}/static-cred/${ROLE}" 2>&1) || {
  echo "    FAIL: Could not read updated credentials."
  echo "    $CREDS_AFTER"
  exit 1
}

PASS_AFTER=$(echo "$CREDS_AFTER" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['password'])")
NEW_ROTATION=$(echo "$CREDS_AFTER" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'].get('last_vault_rotation','N/A'))")

echo "    New password  : ${PASS_AFTER:0:6}****** (truncated)"
echo "    Last rotation : $NEW_ROTATION"

echo ""
if [[ "$PASS_BEFORE" != "$PASS_AFTER" ]]; then
  echo "============================================================"
  echo " ✅ SUCCESS: Password was rotated successfully!"
  echo "    Role  : $ROLE"
  echo "    Mount : $MOUNT"
  echo "    Cred path: ${MOUNT}/static-cred/${ROLE}"
  echo "============================================================"
else
  echo "============================================================"
  echo " ⚠️  WARNING: Password did not change after rotation."
  echo "    This may indicate the rotation did not propagate yet,"
  echo "    or there is a connectivity issue between Vault and LDAP."
  echo "============================================================"
  exit 1
fi

echo ""
echo "Tip: To rotate all roles, run:"
ROLES=("service-account-1" "service-account-2")
for r in "${ROLES[@]}"; do
  echo "  vault write -namespace=$VAULT_NAMESPACE -f ${MOUNT}/rotate-role/${r}"
done
