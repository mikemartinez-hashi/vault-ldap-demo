# ============================================================
# Outputs
# ============================================================

output "ldap_server_public_ip" {
  description = "Public IP of the LDAP server"
  value       = aws_eip.ldap_eip.public_ip
}

output "ldap_base_dn" {
  description = "LDAP base DN"
  value       = local.ldap_base_dn
}

output "ssm_command" {
  description = "SSM command to shell into the LDAP server"
  value       = "aws ssm start-session --target ${aws_instance.ldap_server.id} --region ${var.aws_region}"
}

output "vault_read_creds" {
  description = "Vault commands to read rotated credentials for each static role"
  value = {
    for role_name in keys(vault_ldap_secret_backend_static_role.roles) :
    role_name => "vault read ${var.vault_ldap_mount_path}/static-cred/${role_name}"
  }
}

output "vault_rotate_role" {
  description = "Vault commands to manually trigger rotation for each static role"
  value = {
    for role_name in keys(vault_ldap_secret_backend_static_role.roles) :
    role_name => "vault write -f ${var.vault_ldap_mount_path}/rotate-role/${role_name}"
  }
}
