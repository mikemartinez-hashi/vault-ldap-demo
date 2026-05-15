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

# ---- Ensure AWS SSM Agent is running (idempotent) ----
# Canonical Ubuntu 24.04 AMIs ship with SSM agent pre-installed.
# We just need to make sure it's enabled and running — never abort on this.
echo "==> Configuring AWS SSM Agent..."
{
  if snap list amazon-ssm-agent > /dev/null 2>&1; then
    echo "    SSM Agent already installed via snap - ensuring it is running..."
    snap start amazon-ssm-agent || true
    systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service 2>/dev/null || true
    systemctl start  snap.amazon-ssm-agent.amazon-ssm-agent.service 2>/dev/null || true
  elif systemctl list-units --type=service | grep -q amazon-ssm-agent; then
    echo "    SSM Agent installed as a systemd service - ensuring it is running..."
    systemctl enable amazon-ssm-agent || true
    systemctl start  amazon-ssm-agent  || true
  else
    echo "    SSM Agent not found - installing via snap..."
    snap install amazon-ssm-agent --classic || true
    systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service 2>/dev/null || true
    systemctl start  snap.amazon-ssm-agent.amazon-ssm-agent.service 2>/dev/null || true
  fi
} || true
echo "==> SSM Agent setup complete (non-fatal if any step failed)."

# ---- Install OpenLDAP ----
# debconf-set-selections lives in debconf-utils - must install it first or the
# slapd pre-seed silently does nothing and slapd installs with dc=nodomain.
echo "==> Installing debconf-utils for slapd pre-seeding..."
apt-get install -y debconf-utils

echo "==> Pre-configuring slapd debconf answers..."
debconf-set-selections <<DEBCONF
slapd slapd/password1 password $${LDAP_ADMIN_PASS}
slapd slapd/password2 password $${LDAP_ADMIN_PASS}
slapd slapd/domain string $${LDAP_DOMAIN}
slapd shared/organization string $${LDAP_ORG}
slapd slapd/backend select MDB
slapd slapd/purge_database boolean false
slapd slapd/move_old_database boolean true
slapd slapd/no_configuration boolean false
DEBCONF

echo "==> Verifying debconf pre-seed was accepted..."
debconf-show slapd | grep -E "domain|backend|no_configuration" || true

echo "==> Installing slapd and ldap-utils..."
apt-get install -y slapd ldap-utils

# Safety net: if debconf-set-selections was somehow missed on a previous run
# and slapd is already installed with the wrong base DN, reconfigure it now.
CURRENT_BASE_DN=$$(slapcat 2>/dev/null | grep "^dn:" | head -1 | awk '{print $2}' || true)
echo "==> Detected slapd base DN: $${CURRENT_BASE_DN:-unknown}"
if [[ -n "$${CURRENT_BASE_DN}" && "$${CURRENT_BASE_DN}" != "$${LDAP_BASE_DN}" ]]; then
  echo "==> Base DN mismatch - reconfiguring slapd with correct domain..."
  debconf-set-selections <<DEBCONF2
slapd slapd/password1 password $${LDAP_ADMIN_PASS}
slapd slapd/password2 password $${LDAP_ADMIN_PASS}
slapd slapd/domain string $${LDAP_DOMAIN}
slapd shared/organization string $${LDAP_ORG}
slapd slapd/backend select MDB
slapd slapd/purge_database boolean true
slapd slapd/move_old_database boolean true
slapd slapd/no_configuration boolean false
DEBCONF2
  DEBIAN_FRONTEND=noninteractive dpkg-reconfigure slapd
fi

# ---- Ensure slapd listens on all interfaces (0.0.0.0:389) ----
# Ubuntu 24.04 slapd defaults to ldap:/// (all interfaces) but verify explicitly.
echo "==> Configuring slapd listener..."
if [ -f /etc/default/slapd ]; then
  # Replace or append SLAPD_SERVICES to ensure external + local socket listeners
  if grep -q "^SLAPD_SERVICES" /etc/default/slapd; then
    sed -i 's|^SLAPD_SERVICES=.*|SLAPD_SERVICES="ldap:/// ldapi:///"|' /etc/default/slapd
  else
    echo 'SLAPD_SERVICES="ldap:/// ldapi:///"' >> /etc/default/slapd
  fi
  echo "    /etc/default/slapd updated."
else
  echo "    /etc/default/slapd not found - slapd will use compiled-in defaults (ldap:/// is usually the default)."
fi

# ---- Start slapd ----
systemctl enable slapd
systemctl restart slapd
sleep 5

echo "==> slapd status:"
systemctl is-active slapd || { echo "ERROR: slapd failed to start"; journalctl -u slapd --no-pager -n 30; exit 1; }

# Confirm port 389 is actually listening before proceeding
echo "==> Waiting for port 389 to be open..."
for i in 1 2 3 4 5 6 7 8 9 10; do
  if ss -tlnp | grep -q ':389'; then
    echo "    OK: port 389 is listening (attempt $${i})"
    break
  fi
  echo "    Attempt $${i}: port 389 not yet open - waiting 5s..."
  sleep 5
done
ss -tlnp | grep ':389' || { echo "ERROR: slapd is not listening on port 389 after 50s"; exit 1; }

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

# ---- Verify service accounts ----
echo "==> Verifying service accounts..."
SVC_COUNT=$$(ldapsearch -x -H ldap://localhost \
  -D "cn=admin,$${LDAP_BASE_DN}" \
  -w "$${LDAP_ADMIN_PASS}" \
  -b "ou=ServiceAccounts,$${LDAP_BASE_DN}" \
  "(objectClass=inetOrgPerson)" cn 2>/dev/null \
  | grep -c "^cn:" || true)
echo "==> Found $${SVC_COUNT} service account(s) in ou=ServiceAccounts"

# ---- LDAP logging ----
cat > /etc/rsyslog.d/50-slapd.conf <<'RSYSLOG'
local4.* /var/log/slapd.log
RSYSLOG
systemctl restart rsyslog || true

# ---- Write health check script ----
cat > /usr/local/bin/ldap-healthcheck.sh <<HEALTHCHECK
#!/bin/bash
BASE_DN="$${LDAP_BASE_DN}"
ADMIN_PASS="$${LDAP_ADMIN_PASS}"

echo "=== LDAP Health Check at \$(date) ==="
echo "--- slapd service ---"
systemctl is-active slapd && echo "OK: slapd running" || echo "FAIL: slapd not running"
echo "--- Port 389 ---"
ss -tlnp | grep ':389' && echo "OK: listening on 389" || echo "FAIL: not listening on 389"
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
