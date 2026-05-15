# ============================================================
# Vault LDAP Secrets Engine Configuration
# Configures HCP Vault to manage password rotation for
# LDAP service accounts on the deployed OpenLDAP server.
# ============================================================

# ---- Local values ----
locals {
  # Derive LDAP base DN from domain variable
  # e.g. "example.com" -> "dc=example,dc=com"
  ldap_base_dn = join(",", [for part in split(".", var.ldap_domain) : "dc=${part}"])

  # Compute full static role configs with auto-derived DNs
  # The DN is constructed as: cn=<username>,ou=ServiceAccounts,<base_dn>
  # This matches what user_data.sh creates on the LDAP server.
  ldap_static_roles_computed = {
    for role_name, role in var.ldap_static_roles : role_name => {
      username        = role.username
      dn              = "cn=${role.username},ou=ServiceAccounts,${local.ldap_base_dn}"
      rotation_period = role.rotation_period
    }
  }
}

# ---- Enable and configure Vault LDAP Secrets Engine ----
resource "vault_ldap_secret_backend" "ldap" {
  namespace = var.vault_namespace
  path      = var.vault_ldap_mount_path

  # Bind credentials - admin account used for this demo.
  # In production, replace with a dedicated service account with minimal permissions.
  binddn   = "cn=admin,${local.ldap_base_dn}"
  bindpass = var.ldap_admin_password

  # Connect to the EC2 LDAP server via its public IP.
  # Using plain LDAP (389) for this demo - use LDAPS in production.
  url          = "ldap://${aws_eip.ldap_eip.public_ip}"
  insecure_tls = true

  # Where Vault should look for user accounts
  userdn   = "ou=ServiceAccounts,${local.ldap_base_dn}"
  userattr = "cn"

  # Description
  description = "LDAP secrets engine for AWS LDAP demo - managed by HCP Terraform"

  # Wait for EC2 instance to be fully provisioned before configuring
  depends_on = [aws_instance.ldap_server, aws_eip.ldap_eip]
}

# ---- Create Static Roles for Password Rotation ----
# Each static role tracks one LDAP service account and rotates
# its password on the defined schedule.
resource "vault_ldap_secret_backend_static_role" "roles" {
  for_each = local.ldap_static_roles_computed

  namespace = var.vault_namespace
  mount     = vault_ldap_secret_backend.ldap.path

  role_name       = each.key
  username        = each.value.username
  dn              = each.value.dn
  rotation_period = each.value.rotation_period
}
