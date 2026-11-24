terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ==========================================
# VARIABLES
# ==========================================

variable "aws_access_key" {
  description = "AWS Access Key ID"
  sensitive   = true
}

variable "aws_secret_key" {
  description = "AWS Secret Access Key"
  sensitive   = true
}

variable "aws_region" {
  default     = "eu-central-1" # Europe (Frankfurt)
  description = "AWS region to deploy resources"
}

variable "public_key" {
  description = "Path to the SSH public key file"
}

provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
}

# ==========================================
# DATA SOURCES & SSH KEY
# ==========================================

# Dynamically fetch the latest Ubuntu AMI from Canonical
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical's official AWS account ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-*-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Import SSH public key
resource "aws_key_pair" "default" {
  key_name   = "publickey"
  public_key = file(var.public_key)
}

# ==========================================
# VARIABLES FOR DYNAMIC PORTS (CYCLE 2)
# ==========================================
variable "jenkins_port" {
  description = "Dynamic NodePort for Jenkins (opened in cycle 2)"
  type        = number
  default     = null
}

variable "argocd_port" {
  description = "Dynamic NodePort for Argo CD (opened in cycle 2)"
  type        = number
  default     = null
}

variable "nginx_demo_port" {
  description = "Dynamic NodePort for Nginx Demo application (opened in cycle 2)"
  type        = number
  default     = null
}

# ==========================================
# SECURITY GROUPS (KUBERNETES CLUSTER)
# ==========================================

# 1. Security Group for NODE
resource "aws_security_group" "node_sg" {
  name        = "knode-sg"
  description = "Security group for Kubernetes worker node"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 2. Security Group for SERVER
resource "aws_security_group" "server_sg" {
  name        = "kserver-sg"
  description = "Security group for Kubernetes control plane server"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- SSH ACCESS ---
resource "aws_security_group_rule" "node_ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.node_sg.id
}

resource "aws_security_group_rule" "server_ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.server_sg.id
}

# --- INTERNAL CLUSTER TRAFFIC (ALL PROTOCOLS INCLUDING IP-IN-IP FOR CALICO) ---

# NODE <-> SERVER
resource "aws_security_group_rule" "server_from_node" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.server_sg.id
  source_security_group_id = aws_security_group.node_sg.id
}

resource "aws_security_group_rule" "node_from_server" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.node_sg.id
  source_security_group_id = aws_security_group.server_sg.id
}

# NODE <-> NODE (When additional nodes are added!)
resource "aws_security_group_rule" "node_self" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  self              = true
  security_group_id = aws_security_group.node_sg.id
}

# SERVER <-> SERVER
resource "aws_security_group_rule" "server_self" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  self              = true
  security_group_id = aws_security_group.server_sg.id
}

# --- DYNAMIC APPLICATION PORTS (OPENED IN CYCLE 2) ---
resource "aws_security_group_rule" "server_jenkins_access" {
  count             = var.jenkins_port != null ? 1 : 0
  type              = "ingress"
  from_port         = var.jenkins_port
  to_port           = var.jenkins_port
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.server_sg.id
}

resource "aws_security_group_rule" "server_argocd_access" {
  count             = var.argocd_port != null ? 1 : 0
  type              = "ingress"
  from_port         = var.argocd_port
  to_port           = var.argocd_port
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.server_sg.id
}

resource "aws_security_group_rule" "server_nginx_demo_access" {
  count             = var.nginx_demo_port != null ? 1 : 0
  type              = "ingress"
  from_port         = var.nginx_demo_port
  to_port           = var.nginx_demo_port
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.server_sg.id
}

# ==========================================
# SERVER (CONTROL PLANE)
# ==========================================

resource "aws_instance" "server" {
  count                  = 1
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.large" # 2 vCPU, 8GB RAM
  key_name               = aws_key_pair.default.key_name
  vpc_security_group_ids = [aws_security_group.server_sg.id]
  source_dest_check      = false # Required for Kubernetes CNI pod routing

  root_block_device {
    volume_size           = 30 # Size in GB (default 8 GB is too little for K8s)
    volume_type           = "gp3"
    delete_on_termination = true
  }

  # Enable direct root SSH login using the imported public key
  user_data = <<-EOF
              #!/bin/bash
              hostnamectl set-hostname kserver01r01
              echo "127.0.1.1 kserver01r01" >> /etc/hosts
              sed -i 's/^.*ssh-rsa/ssh-rsa/' /root/.ssh/authorized_keys
              sed -i 's/^.*ssh-ed25519/ssh-ed25519/' /root/.ssh/authorized_keys
              sed -i 's/^.*ecdsa-sha2/ecdsa-sha2/' /root/.ssh/authorized_keys
              sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
              systemctl restart ssh || systemctl restart sshd
              EOF

  tags = {
    Name = "kserver01r01"
  }
}

resource "aws_eip" "server_eip" {
  count    = 1
  instance = aws_instance.server[0].id
  domain   = "vpc"

  tags = {
    Name = "eip-kserver01r01"
  }
}

resource "aws_ebs_volume" "volume_server" {
  availability_zone = aws_instance.server[0].availability_zone
  size              = 5
  type              = "gp3"

  tags = {
    Name        = "volume-kserver01r01"
    Description = "Additional 5GB for server01r01"
  }
}

resource "aws_volume_attachment" "volume_attach_server" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.volume_server.id
  instance_id = aws_instance.server[0].id
}

# ==========================================
# NODE (WORKER)
# ==========================================

resource "aws_instance" "node" {
  count                  = 1
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.medium" # 2 vCPU, 4GB RAM
  key_name               = aws_key_pair.default.key_name
  vpc_security_group_ids = [aws_security_group.node_sg.id]
  source_dest_check      = false # Required for Kubernetes CNI pod routing

  root_block_device {
    volume_size           = 30 # Size in GB (default 8 GB is too little for K8s)
    volume_type           = "gp3"
    delete_on_termination = true
  }

  # Enable direct root SSH login using the imported public key
  user_data = <<-EOF
              #!/bin/bash
              hostnamectl set-hostname knode01r01
              echo "127.0.1.1 knode01r01" >> /etc/hosts
              sed -i 's/^.*ssh-rsa/ssh-rsa/' /root/.ssh/authorized_keys
              sed -i 's/^.*ssh-ed25519/ssh-ed25519/' /root/.ssh/authorized_keys
              sed -i 's/^.*ecdsa-sha2/ecdsa-sha2/' /root/.ssh/authorized_keys
              sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
              systemctl restart ssh || systemctl restart sshd
              EOF

  tags = {
    Name = "knode01r01"
  }
}

resource "aws_eip" "node_eip" {
  count    = 1
  instance = aws_instance.node[0].id
  domain   = "vpc"

  tags = {
    Name = "eip-knode01r01"
  }
}

resource "aws_ebs_volume" "volume_node" {
  availability_zone = aws_instance.node[0].availability_zone
  size              = 5
  type              = "gp3"

  tags = {
    Name        = "volume-knode01r01"
    Description = "Additional 5GB for knode01r01"
  }
}

resource "aws_volume_attachment" "volume_attach_node" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.volume_node.id
  instance_id = aws_instance.node[0].id
}

# ==========================================
# OUTPUTS
# ==========================================

output "ipv4_public_s" {
  value = aws_eip.server_eip[*].public_ip
}

output "ipv4_private_s" {
  value = aws_instance.server[*].private_ip
}

output "ipv4_public_n" {
  value = aws_eip.node_eip[*].public_ip
}

output "ipv4_private_n" {
  value = aws_instance.node[*].private_ip
}
