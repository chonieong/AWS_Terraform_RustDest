
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.0.0-beta2"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Generate an RSA key pair
resource "tls_private_key" "rsa_key" {
  algorithm = "RSA"
  rsa_bits  = 2048  # AWS supports 2048 or 4096 bits
}

# Create an AWS key pair using the public key
resource "aws_key_pair" "ec2_key_pair" {
  key_name   = "my-key-pair"  # Name of the key pair in AWS
  public_key = tls_private_key.rsa_key.public_key_openssh
}

# Save the private key to a .pem file locally
resource "local_file" "private_key" {
  content         = tls_private_key.rsa_key.private_key_pem
  filename        = "${path.module}/my-key-pair.pem"
  file_permission = "0400"  # Restrict permissions to owner read-only
}

resource "aws_instance" "instance_1" {
  ami             = "ami-011899242bb902164" # Ubuntu 20.04 LTS // us-east-1
  instance_type   = "t2.micro"
  security_groups = [aws_security_group.instances.name]
  key_name      = aws_key_pair.ec2_key_pair.key_name
  associate_public_ip_address = true
  # User data script to install Docker
  user_data = <<-EOF
    #!/bin/bash
    # Update package index and install prerequisites
    apt-get update
    apt-get install -y docker.io docker-compose

    # Start and enable Docker service
    systemctl start docker
    systemctl enable docker

    # Create directory for RustDesk
    mkdir -p /home/ubuntu/rustdeskdocker
    cd /home/ubuntu/rustdeskdocker

    # Create docker-compose.yml file
    cat << 'EOL' > /home/ubuntu/rustdeskdocker/docker-compose.yml
    version: '3'
    services:
      hbbs:
        container_name: hbbs
        image: rustdesk/rustdesk-server:latest
        command: hbbs
        volumes:
          - ./data:/root
        network_mode: "host"

        depends_on:
          - hbbr
        restart: unless-stopped

      hbbr:
        container_name: hbbr
        image: rustdesk/rustdesk-server:latest
        command: hbbr
        volumes:
          - ./data:/root
        network_mode: "host"
        restart: unless-stopped
    EOL
    
    # Set proper permissions
    chown -R ubuntu:ubuntu /home/ubuntu/rustdeskdocker

    # Start Docker Compose services
    docker-compose up -d

EOF

  # For showing the RustDesk key
  # Provisioner to copy RustDesk key to a temporary file
  provisioner "remote-exec" {
    inline = [

      "sleep 120",  # Wait 120 seconds for containers to initialize
      "ls -l /home/ubuntu/rustdeskdocker/data || echo 'Data directory not found'",  # Verify data directory
      "cat /home/ubuntu/rustdeskdocker/data/id_ed25519.pub > /tmp/output.txt || echo 'Key file not found'",
      "chmod 644 /tmp/output.txt"
    ]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file(local_file.private_key.filename) # Path to your private key
      host        = self.public_ip
      timeout     = "5m"
    }
  }
  
  # Provisioner to copy the file back to local machine
  provisioner "local-exec" {
    command = "scp -i /workspaces/AWS/RustDesk/my-key-pair.pem -o StrictHostKeyChecking=no ubuntu@${self.public_ip}:/tmp/output.txt output.txt"
  }
  
  tags = {
    Name = "yuri20250730-docker-instance"
  }
}


resource "aws_default_vpc" "default" {
  tags = {
    Name = "Default VPC"
  }
}

resource "aws_security_group" "instances" {
  name = "yuri20250730-instance-security-group"
}

# RustDesk requires these ports to be open: tcp/21115-21119, udp/21116
resource "aws_security_group_rule" "allow_RestDeskTCP_inbound" {
  type              = "ingress"
  security_group_id = aws_security_group.instances.id

  from_port   = 21115
  to_port     = 21119
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]

}

resource "aws_security_group_rule" "allow_RestDeskUdp_inbound" {
  type              = "ingress"
  security_group_id = aws_security_group.instances.id

  from_port   = 21116
  to_port     = 21116
  protocol    = "udp"
  cidr_blocks = ["0.0.0.0/0"]

}

resource "aws_security_group_rule" "allow_ssh_inbound" {
  type              = "ingress"
  security_group_id = aws_security_group.instances.id

  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]

}

resource "aws_security_group_rule" "allow_outbound" {
  type              = "egress"
  security_group_id = aws_security_group.instances.id

  from_port   = 0
  to_port     = 0
  protocol    = "-1"
  cidr_blocks = ["0.0.0.0/0"]

}

output "instance_public_ip" {
  value = aws_instance.instance_1.public_ip
}

output "key_pair_name" {
  value = aws_key_pair.ec2_key_pair.key_name
}

# Output the key of RustDesk
output "key_RustDesk" {
  value       = fileexists("${path.module}/output.txt") ? file("${path.module}/output.txt") : "File not created"
  description = "Content of the output.txt file from the EC2 instance"
  depends_on = [ aws_instance.instance_1 ]
}