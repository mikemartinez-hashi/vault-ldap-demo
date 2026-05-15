# ============================================================
# Sample Vault Policy - LDAP Static Role Consumer
#
# Apply this policy to tokens/roles that need to READ
# rotated credentials from the LDAP secrets engine.
#
# To write this policy to Vault:
#   vault policy write ldap-consumer sample-policy.hcl
#
# For HCP Vault (namespace = admin):
#   vault policy write -namespace=admin ldap-consumer sample-policy.hcl
# ============================================================

# --- Read rotated credentials for any static role ---
path "ldap/static-cred/*" {
  capabilities = ["read"]
}

# --- Optionally allow listing available roles ---
path "ldap/static-role/" {
  capabilities = ["list"]
}

path "ldap/static-role/*" {
  capabilities = ["read", "list"]
}

# ============================================================
# Sample Vault Policy - LDAP Rotation Operator
#
# Apply this policy to admin tokens that need to manually
# trigger rotations (e.g., break-glass or CI/CD pipelines).
# ============================================================

# --- Manually trigger rotation for any static role ---
path "ldap/rotate-role/*" {
  capabilities = ["create", "update"]
}

# --- Read current credentials (for verification) ---
path "ldap/static-cred/*" {
  capabilities = ["read"]
}

# --- Read LDAP backend config (read-only) ---
path "ldap/config" {
  capabilities = ["read"]
}
