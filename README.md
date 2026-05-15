# AWS LDAP + HCP Vault LDAP Secrets Engine Rotation

Deploys an **OpenLDAP server on AWS EC2** and configures **HCP Vault's LDAP secrets engine** to automatically rotate service account passwords on a schedule. Fully managed via **HCP Terraform** (`mikes_sandbox` org).

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                    HCP Terraform                    │
│              (org: mikes_sandbox)                   │
│         workspace: aws-ldap-vault-rotation          │
└─────────────────┬───────────────────────────────────┘
                  │ manages
       ┌──────────┴──────────┐
       ▼                     ▼
┌─────────────┐      ┌───────────────────┐
│   AWS (EC2) │      │    HCP Vault      │
│             │      │  (admin ns)       │
│ ┌─────────┐ │      │                   │
│ │ OpenLDAP│◄├──────┤ LDAP Secrets Eng  │
│ │ :389    │ │      │ Mount: ldap/      │
│ └─────────┘ │      │                   │
│   Ubuntu    │      │ Static Roles:     │
│   24.04 LTS │      │  - service-acct-1 │
│   EIP       │      │  - service-acct-2 │
└─────────────┘      └───────────────────┘
       ▲
       │ bootstrapped by
  user_data.sh
  (slapd + OUs + service accounts)
```

**Flow:** Terraform provisions the EC2 instance → `user_data.sh` installs OpenLDAP and creates service accounts → Terraform configures Vault LDAP secrets engine pointing to the EC2 IP → Vault rotates passwords on schedule.

---

## Prerequisites

- HCP Terraform access (`mikes_sandbox` org)
- HCP Vault cluster (already connected to HCP Terraform workspace)
- AWS credentials configured in the HCP TF workspace
- Terraform CLI ≥ 1.6.0 (for local runs)
- Vault CLI (for verification scripts)

---

## HCP Terraform Workspace Variables

Set these in the `aws-ldap-vault-rotation` workspace in HCP Terraform:

### Environment Variables

| Variable | Sensitive | Value |
|---|---|---|
| `VAULT_ADDR` | No | `https://your-cluster.hashicorp.cloud:8200` |
| `VAULT_TOKEN` | **Yes** | Your HCP Vault admin token |
| `VAULT_NAMESPACE` | No | `admin` |
| `AWS_ACCESS_KEY_ID` | **Yes** | Your AWS access key |
| `AWS_SECRET_ACCESS_KEY` | **Yes** | Your AWS secret key |

### Terraform Variables

| Variable | Sensitive | Default | Description |
|---|---|---|---|
| `vault_addr` | No | — | Same as `VAULT_ADDR` env var |
| `ldap_admin_password` | **Yes** | — | LDAP admin password (min 8 chars) |
| `ldap_domain` | No | `example.com` | Your LDAP domain |
| `ldap_organization` | No | `Example Organization` | Org display name |
| `vault_namespace` | No | `admin` | Vault namespace |
| `aws_region` | No | `us-east-1` | AWS region |
| `ssh_public_key` | **Yes** | `null` | Optional — SSH public key (SSM is default) |

---

## Repository Structure

```
aws-ldap-vault-rotation/
├── terraform/
│   ├── main.tf           # AWS infrastructure (VPC, EC2, SG, IAM, EIP)
│   ├── vault_config.tf   # Vault LDAP secrets engine + static roles
│   ├── variables.tf      # All input variables
│   ├── outputs.tf        # Outputs (IPs, Vault paths, quick reference)
│   └── user_data.sh      # EC2 bootstrap: installs OpenLDAP + creates accounts
├── vault/
│   ├── verify-rotation.sh  # Verifies credential rotation end-to-end
│   └── sample-policy.hcl   # Example Vault policies for consumers
├── scripts/
│   └── test-ldap.sh        # Run on EC2 to validate LDAP setup
└── README.md
```

---

## Deploy

### Via HCP Terraform (recommended)

1. Push this repository to GitHub (or your connected VCS).
2. In HCP Terraform, create/connect the workspace `aws-ldap-vault-rotation` to your VCS repo with working directory `terraform/`.
3. Set all required workspace variables (see table above).
4. Queue a plan → review → **Apply**.

### Local CLI (for development)

```bash
cd terraform/

# Authenticate to HCP Terraform
terraform login

# Initialize (pulls remote state from HCP TF)
terraform init

# Plan
terraform plan

# Apply
terraform apply
```

---

## What Gets Created

### AWS Resources
| Resource | Description |
|---|---|
| VPC (`10.0.0.0/16`) | Dedicated VPC for LDAP |
| Public Subnet | `10.0.1.0/24` |
| Internet Gateway + Route Table | Public internet access |
| Security Group | Allows LDAP (389), LDAPS (636), SSH (22) |
| EC2 (Ubuntu 24.04, t3.medium) | OpenLDAP server |
| Elastic IP | Static public IP for Vault → LDAP connectivity |
| IAM Role + Instance Profile | SSM Session Manager access |

### LDAP Structure (created by `user_data.sh`)
```
dc=example,dc=com
├── ou=ServiceAccounts
│   ├── cn=svc-app1    ← rotated by Vault
│   └── cn=svc-app2    ← rotated by Vault
├── ou=Users
└── ou=Groups
```

### Vault Resources
| Resource | Path |
|---|---|
| LDAP Secrets Engine | `ldap/` |
| Static Role (App1) | `ldap/static-role/service-account-1` |
| Static Role (App2) | `ldap/static-role/service-account-2` |

---

## Reading Rotated Credentials

After apply, Vault immediately rotates the initial passwords. Retrieve them:

```bash
# Set Vault connection
export VAULT_ADDR="https://your-cluster.hashicorp.cloud:8200"
export VAULT_TOKEN="hvs.xxxx"
export VAULT_NAMESPACE="admin"

# Read credentials for service-account-1
vault read ldap/static-cred/service-account-1

# Read credentials for service-account-2
vault read ldap/static-cred/service-account-2
```

Example output:
```
Key                    Value
---                    -----
last_vault_rotation    2024-01-15T10:30:00Z
password               <rotated-password>
rotation_period        86400
ttl                    85400
username               svc-app1
```

---

## Manual Rotation (On-Demand)

```bash
# Rotate immediately (useful for break-glass scenarios)
vault write -f ldap/rotate-role/service-account-1
vault write -f ldap/rotate-role/service-account-2
```

Or use the verification script which reads before/after and confirms:

```bash
chmod +x vault/verify-rotation.sh
./vault/verify-rotation.sh ldap service-account-1
```

---

## Verifying LDAP on the EC2 Instance

### Via SSM (no SSH key needed)
```bash
# Get instance ID from Terraform output
INSTANCE_ID=$(terraform -chdir=terraform output -raw ldap_server_instance_id)

# Start SSM session
aws ssm start-session --target $INSTANCE_ID --region us-east-1

# On the instance:
/usr/local/bin/ldap-healthcheck.sh
```

### Via the test script (run on the instance)
```bash
# Copy the script to the instance first, or run in SSM:
sudo /bin/bash /path/to/scripts/test-ldap.sh "dc=example,dc=com" "YourAdminPass"
```

---

## Customizing Static Roles

To add more service accounts, update the `ldap_static_roles` workspace variable (or override in a `.tfvars` file):

```hcl
ldap_static_roles = {
  "app-database" = {
    username        = "svc-db"
    rotation_period = 43200  # 12 hours
  }
  "app-api" = {
    username        = "svc-api"
    rotation_period = 86400  # 24 hours
  }
}
```

> **Note:** The service accounts must also exist in LDAP. Update `user_data.sh` to create them before adding them as static roles, or create them manually via `ldapadd` on the server.

---

## Security Notes

- **Plain LDAP (port 389)** is used in this demo. In production, configure LDAPS (port 636) with a valid TLS certificate and set `insecure_tls = false` in `vault_config.tf`.
- **Admin bind account** is used by Vault in this demo. In production, create a dedicated bind account with only the permissions needed to modify passwords.
- **Restrict `allowed_cidr_blocks`** in the security group. The current default (`0.0.0.0/0`) is for demo convenience only.
- Vault manages all credential rotation — no secrets should be stored in application configs.

---

## Cleanup

```bash
terraform -chdir=terraform destroy
```

This removes all AWS resources. The Vault LDAP secrets engine resources are also destroyed (Vault will be left in a clean state for the mount path).
