#!/bin/bash
# OpenLDAP Bootstrap Script - Deployed and managed via HCP Terraform

set -euo pipefail

# ---- Values injected by Terraform templatefile() ----
LDAP_DOMAIN="${ldap_domain}"
LDAP_ORG="${ldap_organization}"
LDAP_ADMIN_PASS="${ldap_admin_password}"
LDAP_BASE_DN="${ldap_base_dn}"
VAULT_ADDR="${vault_addr}"
VAULT_NAMESPACE="${vault_namespace}"

# ---- Logging ----
LOG_FILE="/var/log/ldap-bootstrap.log"
exec > >(tee -a "$${LOG_FILE}" | logger -t ldap-bootstrap -s 2>/dev/console) 2>&1
echo "============================================================"
echo "LDAP Bootstrap starting at $$(date -u)"
echo "Domain   : $${LDAP_DOMAIN}"
echo "Base DN  : $${LDAP_BASE_DN}"
echo "Vault    : $${VAULT_ADDR}"
echo "============================================================"

# ---- System update ----
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y -q

# ---- Install AWS SSM Agent (not pre-installed on Canonical Ubuntu 24.04) ----
# Using snap - the AWS-recommended method for Ubuntu.
echo "==> Installing AWS SSM Agent..."
snap install amazon-ssm-agent --classic
systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service
sleep 3

SSM_STATUS=$$(systemctl is-active snap.amazon-ssm-agent.amazon-ssm-agent.service || true)
echo "==> SSM Agent status: $${SSM_STATUS}"
if [[ "$${SSM_STATUS}" != "active" ]]; then
  echo "WARNING: SSM Agent may not have started - check 'systemctl status snap.amazon-ssm-agent.amazon-ssm-agent.service'"
else
  echo "==> SSM Agent running. Session Manager is available."
fi

# ---- Install OpenLDAP packages ----
# Pre-configure slapd non-interactively
debconf-set-selections <<DEBCONF
slapd slapd/password1 password $${LDAP_ADMIN_PASS}
slapd slapd/password2 password $${LDAP_ADMIN_PASS}
slapd slapd/domain string $${LDAP_DOMAIN}
slapd shared/organization string $${LDAP_ORG}
slapd slapd/backend select MDB
slapd slapd/purge_database boolean false
slapd slapd/move_old_database boolean true
slapd slapd/no_configuration boolean false
slapd slapd/dump_database select when needed
DEBCONF

apt-get install -y slapd ldap-utils

# ---- Enable and start slapd ----
systemctl enable slapd
systemctl start slapd
sleep 5

echo "==> slapd status:"
systemctl is-active slapd || { echo "ERROR: slapd failed to start"; exit 1; }

# ---- Verify base DIT ----
echo "==> Verifying base DN: $${LDAP_BASE_DN}"
ldapsearch -x -H ldap://localhost \
  -b "$${LDAP_BASE_DN}" \
  -D "cn=admin,$${LDAP_BASE_DN}" \
  -w "$${LDAP_ADMIN_PASS}" \
  "(objectClass=top)" dn \
  && echo "==> Base DIT confirmed." \
  || echo "WARNING: Base DIT search returned non-zero - continuing..."

# ---- Create Organizational Units ----
echo "==> Creating Organizational Units..."
ldapadd -x -H ldap://localhost \
  -D "cn=admin,$${LDAP_BASE_DN}" \
  -w "$${LDAP_ADMIN_PASS}" <<LDIF || true
dn: ou=ServiceAccounts,$${LDAP_BASE_DN}
objectClass: organizationalUnit
ou: ServiceAccounts
description: Service accounts managed by HCP Vault LDAP secrets engine

dn: ou=Users,$${LDAP_BASE_DN}
objectClass: organizationalUnit
ou: Users
description: Standard user accounts

dn: ou=Groups,$${LDAP_BASE_DN}
objectClass: organizationalUnit
ou: Groups
description: LDAP groups
LDIF

# ---- Create Service Accounts ----
echo "==> Creating service accounts..."
INITIAL_SVC_PASS=$$(openssl rand -base64 24)

ldapadd -x -H ldap://localhost \
  -D "cn=admin,$${LDAP_BASE_DN}" \
  -w "$${LDAP_ADMIN_PASS}" <<LDIF || true
dn: cn=svc-app1,ou=ServiceAccounts,$${LDAP_BASE_DN}
objectClass: inetOrgPerson
objectClass: simpleSecurityObject
cn: svc-app1
sn: svc-app1
userPassword: $${INITIAL_SVC_PASS}
description: Service account for App1 - password managed by HCP Vault

dn: cn=svc-app2,ou=ServiceAccounts,$${LDAP_BASE_DN}
objectClass: inetOrgPerson
objectClass: simpleSecurityObject
cn: svc-app2
sn: svc-app2
userPassword: $${INITIAL_SVC_PASS}
description: Service account for App2 - password managed by HCP Vault
LDIF

# ---- LDAP logging ----
echo "==> Configuring LDAP logging..."
cat > /etc/rsyslog.d/50-slapd.conf <<'RSYSLOG'
local4.* /var/log/slapd.log
RSYSLOG
systemctl restart rsyslog || true

# ---- Ensure slapd listens on all interfaces ----
echo "==> Updating slapd listener config..."
sed -i 's|SLAPD_SERVICES=.*|SLAPD_SERVICES="ldap:/// ldapi:///"|' /etc/default/slapd 2>/dev/null || true
systemctl restart slapd
sleep 3

# ---- Verify service accounts ----
echo "==> Verifying service accounts..."
SVC_COUNT=$$(ldapsearch -x -H ldap://localhost \
  -D "cn=admin,$${LDAP_BASE_DN}" \
  -w "$${LDAP_ADMIN_PASS}" \
  -b "ou=ServiceAccounts,$${LDAP_BASE_DN}" \
  "(objectClass=inetOrgPerson)" cn 2>/dev/null \
  | grep -c "^cn:" || true)
echo "==> Found $${SVC_COUNT} service account(s) in ou=ServiceAccounts"

# ---- Write health check script ----
cat > /usr/local/bin/ldap-healthcheck.sh <<HEALTHCHECK
#!/bin/bash
# LDAP Health Check
BASE_DN="$${LDAP_BASE_DN}"
ADMIN_PASS="$${LDAP_ADMIN_PASS}"

echo "=== LDAP Health Check at \$(date) ==="

echo "--- slapd service ---"
systemctl is-active slapd && echo "OK: slapd running" || echo "FAIL: slapd not running"

echo "--- LDAP connectivity ---"
ldapsearch -x -H ldap://localhost -b "\$${BASE_DN}" \
  -D "cn=admin,\$${BASE_DN}" -w "\$${ADMIN_PASS}" \
  "(objectClass=top)" dn 2>&1 | head -20

echo "--- Service accounts ---"
ldapsearch -x -H ldap://localhost \
  -D "cn=admin,\$${BASE_DN}" -w "\$${ADMIN_PASS}" \
  -b "ou=ServiceAccounts,\$${BASE_DN}" \
  "(objectClass=inetOrgPerson)" cn description 2>&1

echo "=== Health check complete ==="
HEALTHCHECK
chmod +x /usr/local/bin/ldap-healthcheck.sh

# ---- Write Vault connection info ----
cat > /etc/ldap-vault-info.env <<VAULTENV
VAULT_ADDR=$${VAULT_ADDR}
VAULT_NAMESPACE=$${VAULT_NAMESPACE}
LDAP_BASE_DN=$${LDAP_BASE_DN}
LDAP_DOMAIN=$${LDAP_DOMAIN}
VAULTENV
chmod 600 /etc/ldap-vault-info.env

echo "============================================================"
echo "LDAP Bootstrap COMPLETE at $$(date -u)"
echo "Base DN : $${LDAP_BASE_DN}"
echo "Accounts: cn=svc-app1,ou=ServiceAccounts,$${LDAP_BASE_DN}"
echo "          cn=svc-app2,ou=ServiceAccounts,$${LDAP_BASE_DN}"
echo "Run /usr/local/bin/ldap-healthcheck.sh to verify."
echo "============================================================"
