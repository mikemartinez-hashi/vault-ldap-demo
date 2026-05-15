# AWS LDAP Server with HCP Vault Integration
# This configuration deploys an OpenLDAP server on AWS EC2

terraform {
  required_version = ">= 1.6.0"
  
  cloud {
    organization = "mikes_sandbox"
    
    workspaces {
      name = "aws-ldap-vault-rotation"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  
  default_tags {
    tags = {
      Environment = var.environment
      Project     = "LDAP-Vault-Rotation"
      ManagedBy   = "Terraform"
    }
  }
}

provider "vault" {
  # HCP Vault connection - configured via HCP Terraform workspace variables
  # VAULT_ADDR and VAULT_TOKEN should be set as environment variables
}

# Public Ubuntu 24.04 LTS AMI (Canonical)
# Using the official Canonical AMI to ensure broad AWS account access.
data "aws_ami" "ubuntu_24_04" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# VPC Configuration
resource "aws_vpc" "ldap_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "ldap_igw" {
  vpc_id = aws_vpc.ldap_vpc.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

# Public Subnet
resource "aws_subnet" "ldap_public_subnet" {
  vpc_id                  = aws_vpc.ldap_vpc.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-subnet"
  }
}

# Route Table
resource "aws_route_table" "ldap_public_rt" {
  vpc_id = aws_vpc.ldap_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.ldap_igw.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

# Route Table Association
resource "aws_route_table_association" "ldap_public_rta" {
  subnet_id      = aws_subnet.ldap_public_subnet.id
  route_table_id = aws_route_table.ldap_public_rt.id
}

# Data source for availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

# Security Group for LDAP Server
resource "aws_security_group" "ldap_sg" {
  name        = "${var.project_name}-ldap-sg"
  description = "Security group for LDAP server"
  vpc_id      = aws_vpc.ldap_vpc.id

  # LDAP
  ingress {
    description = "LDAP"
    from_port   = 389
    to_port     = 389
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  # LDAPS
  ingress {
    description = "LDAPS"
    from_port   = 636
    to_port     = 636
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  # SSH
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  # Outbound
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-ldap-sg"
  }
}

# IAM Role for EC2 Instance
resource "aws_iam_role" "ldap_instance_role" {
  name = "${var.project_name}-ldap-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-ldap-instance-role"
  }
}

# IAM Instance Profile
resource "aws_iam_instance_profile" "ldap_instance_profile" {
  name = "${var.project_name}-ldap-instance-profile"
  role = aws_iam_role.ldap_instance_role.name
}

# Attach SSM policy for Systems Manager access
resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.ldap_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Key Pair for SSH access (optional - SSM Session Manager is always available)
resource "aws_key_pair" "ldap_key" {
  count      = var.ssh_public_key != null ? 1 : 0
  key_name   = "${var.project_name}-key"
  public_key = var.ssh_public_key

  tags = {
    Name = "${var.project_name}-key"
  }
}

# EC2 Instance for LDAP Server
resource "aws_instance" "ldap_server" {
  ami                    = data.aws_ami.ubuntu_24_04.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.ldap_public_subnet.id
  vpc_security_group_ids = [aws_security_group.ldap_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ldap_instance_profile.name
  key_name               = var.ssh_public_key != null ? aws_key_pair.ldap_key[0].key_name : null

  user_data = templatefile("${path.module}/user_data.sh", {
    ldap_domain         = var.ldap_domain
    ldap_organization   = var.ldap_organization
    ldap_admin_password = var.ldap_admin_password
    vault_addr          = var.vault_addr
    vault_namespace     = var.vault_namespace
    # Derived base DN passed in so the script doesn't need to parse the domain itself
    ldap_base_dn        = local.ldap_base_dn
  })

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "${var.project_name}-ldap-server"
  }

  lifecycle {
    ignore_changes = [user_data]
  }
}

# Elastic IP for LDAP Server
resource "aws_eip" "ldap_eip" {
  instance = aws_instance.ldap_server.id
  domain   = "vpc"

  tags = {
    Name = "${var.project_name}-ldap-eip"
  }

  depends_on = [aws_internet_gateway.ldap_igw]
}