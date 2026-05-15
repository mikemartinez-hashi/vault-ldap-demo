#!/bin/bash
# ============================================================
# LDAP Connectivity Test Script
#
# Run this on the LDAP server (via SSM or SSH) to quickly
# verify the OpenLDAP installation and service account setup.
#
# Usage:
#   ./test-ldap.sh <LDAP_BASE_DN> <LDAP_ADMIN_PASS>
#
# Example:
#   ./test-ldap.sh "dc=example,dc=com" "MyAdminPass123"
# ============================================================

set -euo pipefail

BASE_DN="${1:?Usage: $0 <base_dn> <admin_password>}"
ADMIN_PASS="${2:?Usage: $0 <base_dn> <admin_password>}"
LDAP_URI="ldap://localhost:389"
ADMIN_DN="cn=admin,${BASE_DN}"

PASS_OR_FAIL() {
  if [[ $1 -eq 0 ]]; then
    echo "  ✅ PASS: $2"
  else
    echo "  ❌ FAIL: $2"
  fi
}

echo "============================================================"
echo " LDAP Connectivity Test"
echo " URI      : $LDAP_URI"
echo " Base DN  : $BASE_DN"
echo " Admin DN : $ADMIN_DN"
echo "============================================================"
echo ""

# 1. slapd running?
echo "[1] slapd service status"
systemctl is-active slapd > /dev/null 2>&1
PASS_OR_FAIL $? "slapd is running"

# 2. Anonymous base search
echo ""
echo "[2] Anonymous base search"
ldapsearch -x -H "$LDAP_URI" -b "$BASE_DN" "(objectClass=top)" dn > /dev/null 2>&1
PASS_OR_FAIL $? "Anonymous base search succeeded"

# 3. Admin bind
echo ""
echo "[3] Admin bind"
ldapsearch -x -H "$LDAP_URI" -D "$ADMIN_DN" -w "$ADMIN_PASS" -b "$BASE_DN" "(objectClass=top)" dn > /dev/null 2>&1
PASS_OR_FAIL $? "Admin bind succeeded"

# 4. ServiceAccounts OU
echo ""
echo "[4] ServiceAccounts OU"
ldapsearch -x -H "$LDAP_URI" -D "$ADMIN_DN" -w "$ADMIN_PASS" \
  -b "ou=ServiceAccounts,${BASE_DN}" "(objectClass=organizationalUnit)" dn > /dev/null 2>&1
PASS_OR_FAIL $? "ou=ServiceAccounts exists"

# 5. Service accounts exist
echo ""
echo "[5] Service account entries"
for SVC in svc-app1 svc-app2; do
  ldapsearch -x -H "$LDAP_URI" -D "$ADMIN_DN" -w "$ADMIN_PASS" \
    -b "cn=${SVC},ou=ServiceAccounts,${BASE_DN}" "(objectClass=inetOrgPerson)" cn > /dev/null 2>&1
  PASS_OR_FAIL $? "Service account cn=${SVC} exists"
done

# 6. Show all service accounts
echo ""
echo "[6] Listing all service accounts:"
ldapsearch -x -H "$LDAP_URI" -D "$ADMIN_DN" -w "$ADMIN_PASS" \
  -b "ou=ServiceAccounts,${BASE_DN}" "(objectClass=inetOrgPerson)" cn description 2>&1 \
  | grep -E "^(dn|cn|description):" || echo "  (none found)"

echo ""
echo "============================================================"
echo " Test complete. Check any ❌ FAIL items above."
echo "============================================================"
