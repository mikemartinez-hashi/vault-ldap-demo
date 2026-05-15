# AWS Configuration
variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  # default     = "us-east-2"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "Demo"
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "ldap-vault-rotation"
}

# Network Configuration
variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to access LDAP server"
  type        = list(string)
  default     = ["0.0.0.0/0"] # Restrict this in production
}

# EC2 Configuration
variable "instance_type" {
  description = "EC2 instance type for LDAP server"
  type        = string
  default     = "t3.medium"
}

variable "ssh_public_key" {
  description = "SSH public key for EC2 access (optional - SSM Session Manager is configured by default)"
  type        = string
  sensitive   = true
  default     = null
}

# LDAP Configuration
variable "ldap_domain" {
  description = "LDAP domain (e.g., example.com)"
  type        = string
  default     = "example.com"
}

variable "ldap_organization" {
  description = "LDAP organization name"
  type        = string
  default     = "Example Organization"
}

variable "ldap_admin_password" {
  description = "LDAP admin password"
  type        = string
  sensitive   = true
}

# Vault Configuration
variable "TFC_VAULT_ADDR" {
  description = "HCP Vault cluster address"
  type        = string
}

variable "TFC_VAULT_NAMESPACE" {
  description = "Vault namespace (use 'admin' for HCP Vault)"
  type        = string
  default     = "admin"
}

variable "vault_ldap_mount_path" {
  description = "Mount path for LDAP secrets engine in Vault"
  type        = string
  default     = "ldap"
}

variable "rotation_period" {
  description = "Password rotation period in seconds (default is 120 seconds - 2 minutes)"
  type        = number
  default     = 120 # 2 minutes
}

# LDAP Static Roles Configuration
# The 'dn' is intentionally omitted here and auto-computed in vault_config.tf
# as: cn=<username>,ou=ServiceAccounts,<ldap_base_dn>
# This ensures the DN always matches the accounts created by user_data.sh.
variable "ldap_static_roles" {
  description = "Map of LDAP static roles to create in Vault. DN is auto-derived from username and ldap_domain."
  type = map(object({
    username        = string
    rotation_period = number
  }))
  default = {
    "service-account-1" = {
      username        = "svc-app1"
      rotation_period = 120 # 2 minutes
    }
    "service-account-2" = {
      username        = "svc-app2"
      rotation_period = 120 # 2 minutes
    }
  }
}
