# ============================================================
# Vault LDAP Secrets Engine Configuration
# Configures HCP Vault to manage password rotation for
# LDAP service accounts on the deployed OpenLDAP server.
# ============================================================

# ---- Local values ----
locals {
  ldap_base_dn = join(",", [for part in split(".", var.ldap_domain) : "dc=${part}"])

  # AD DN format: CN=<username>,OU=ServiceAccounts,<base_dn>
  # Must match exactly what New-ADUser creates in user_data.ps1
  ldap_static_roles_computed = {
    for role_name, role in var.ldap_static_roles : role_name => {
      username        = role.username
      dn              = "CN=${role.username},OU=ServiceAccounts,${local.ldap_base_dn}"
      rotation_period = role.rotation_period
    }
  }
}

# ---- Enable and configure Vault LDAP Secrets Engine ----
resource "vault_ldap_secret_backend" "ldap" {
  # namespace inherited from VAULT_NAMESPACE env var - do not set here
  path = var.vault_ldap_mount_path

  # Bind as the built-in Administrator account
  # In AD, Administrator lives in CN=Users, not an OU
  binddn   = "CN=Administrator,CN=Users,${local.ldap_base_dn}"
  bindpass = var.ldap_admin_password

  # LDAPS (port 636, TLS) is required for AD password rotation.
  # insecure_tls=true skips verification of the self-signed cert created in user_data.ps1.
  url          = "ldaps://${aws_eip.ldap_eip.public_ip}"
  insecure_tls = true

  # AD uses sAMAccountName (short login name) as the user identifier
  userdn   = "OU=ServiceAccounts,${local.ldap_base_dn}"
  userattr = "sAMAccountName"

  description = "LDAP secrets engine - Active Directory - managed by HCP Terraform"

  # Wait for full AD DS bootstrap (Phase 1 reboot + Phase 2 account creation)
  depends_on = [time_sleep.wait_for_ldap_bootstrap]
}

# ---- Create Static Roles for Password Rotation ----
# Each static role tracks one LDAP service account and rotates
# its password on the defined schedule.
resource "vault_ldap_secret_backend_static_role" "roles" {
  for_each = local.ldap_static_roles_computed

  # namespace inherited from provider - do not set here
  mount = vault_ldap_secret_backend.ldap.path

  role_name       = each.key
  username        = each.value.username
  dn              = each.value.dn
  rotation_period = each.value.rotation_period
}
