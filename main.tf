# main.tf
# This is a test comment to trigger a new pipeline
# Configure the AWS provider
#naay nasagol nga lobot
# This block tells Terraform that we'll be working with AWS,
# and it will use the credentials configured via 'aws configure'
# or environment variables.
provider "aws" {
  region = "us-east-1" # Set your desired AWS region here (e.g., "ap-southeast-1", "eu-west-1")
}

# 1. Create a Virtual Private Cloud (VPC)
# A VPC is an isolated network where your AWS resources will run.
resource "aws_vpc" "app_vpc" {
  cidr_block       = "10.0.0.0/16" # Define the IP address range for your VPC
  instance_tenancy = "default"    # Default tenancy for instances
  enable_dns_hostnames = true     # Enable DNS hostnames for instances

  tags = {
    Name = "flask-app-vpc"
  }
}

# 2. Create a Public Subnet
# Subnets are subdivisions within a VPC. This one will be public,
# meaning resources in it can communicate with the internet.
resource "aws_subnet" "app_public_subnet" {
  vpc_id                  = aws_vpc.app_vpc.id # Associate with the VPC created above
  cidr_block              = "10.0.1.0/24"      # IP range for the subnet
  map_public_ip_on_launch = true              # Automatically assign public IPs to instances launched in this subnet
  availability_zone       = "${var.aws_region}a" # Use the first AZ in the region (e.g., us-east-1a)

  tags = {
    Name = "flask-app-public-subnet"
  }
}

# 3. Create an Internet Gateway
# An Internet Gateway allows communication between your VPC and the internet.
resource "aws_internet_gateway" "app_igw" {
  vpc_id = aws_vpc.app_vpc.id # Attach to your VPC

  tags = {
    Name = "flask-app-igw"
  }
}

# 4. Create a Route Table
# A Route Table dictates where network traffic from subnets is directed.
resource "aws_route_table" "app_route_table" {
  vpc_id = aws_vpc.app_vpc.id # Associate with your VPC

  route {
    cidr_block = "0.0.0.0/0"    # Destination for all internet traffic
    gateway_id = aws_internet_gateway.app_igw.id # Route it through the Internet Gateway
  }

  tags = {
    Name = "flask-app-route-table"
  }
}

# 5. Associate the Route Table with the Public Subnet
# This step links the subnet to the route table, making it a public subnet.
resource "aws_route_table_association" "app_route_table_association" {
  subnet_id      = aws_subnet.app_public_subnet.id
  route_table_id = aws_route_table.app_route_table.id
}

# 6. Create a Security Group for the EC2 Instance
# A security group acts as a virtual firewall for your EC2 instance.
# We'll allow SSH (port 22) and HTTP (port 80) access from anywhere.
resource "aws_security_group" "app_sg" {
  name        = "flask-app-security-group"
  description = "Allow SSH and HTTP inbound traffic"
  vpc_id      = aws_vpc.app_vpc.id

  # Inbound rule for SSH (Port 22)
  ingress {
    description = "SSH from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Be cautious: 0.0.0.0/0 means open to the world. Restrict in production.
  }

  # Inbound rule for HTTP (Port 80) for your Flask app
  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Be cautious: 0.0.0.0/0 means open to the world. Restrict in production.
  }

  # Outbound rule (allow all outbound traffic)
  # This is usually fine for development, but can be restricted in production.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # -1 means all protocols
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "flask-app-sg"
  }
}

# 7. Create an IAM Role and Instance Profile for the EC2 Instance (Best Practice)
# This allows the EC2 instance to assume a role and perform actions on other AWS services
# without storing credentials directly on the instance.
resource "aws_iam_role" "app_ec2_role" {
  name = "flask_app_ec2_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })

  tags = {
    Name = "flask-app-ec2-role"
  }
}

# Attach a policy to the role (e.g., CloudWatchLogs for logging)
# We'll attach a basic policy that allows the instance to send logs to CloudWatch,
# which is good practice for application monitoring.
resource "aws_iam_role_policy_attachment" "app_ec2_role_policy_attachment" {
  role       = aws_iam_role.app_ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy" # Allows writing logs to CloudWatch
}

# Create an Instance Profile to attach the role to the EC2 instance
resource "aws_iam_instance_profile" "app_ec2_instance_profile" {
  name = "flask_app_ec2_instance_profile"
  role = aws_iam_role.app_ec2_role.name
}

# 8. Define the EC2 Instance
# This is the virtual server where your Flask app will run.
resource "aws_instance" "flask_app_instance" {
  ami           = data.aws_ami.amazon_linux_2.id # Use the AMI ID retrieved below
  instance_type = "t2.micro"                      # Small, free-tier eligible instance type
  subnet_id     = aws_subnet.app_public_subnet.id # Launch in the public subnet
  security_groups = [aws_security_group.app_sg.id] # Attach the security group
  associate_public_ip_address = true               # Assign a public IP for internet access
  iam_instance_profile = aws_iam_instance_profile.app_ec2_instance_profile.name # Attach IAM role
  key_name                    = "my-flask-app-key" # <-- ADD THIS LINE

  # User data to install Python, Flask, and run the app upon launch
  # This script runs once when the instance starts for the first time.
  user_data = <<-EOF
              #!/bin/bash
              sudo yum update -y
              sudo yum install -y python3-pip
              sudo pip3 install flask gunicorn # Gunicorn is a production-ready WSGI server
              # Create a directory for your application
              mkdir /home/ec2-user/flask_app
              cd /home/ec2-user/flask_app
              # This is where you would place your app.py content
              cat << 'EOT' > app.py
              from flask import Flask
              app = Flask(__name__)
              @app.route('/')
              def hello_world():
                  return 'Hello, World from EC2!'
              if __name__ == '__main__':
                  app.run(host='0.0.0.0', port=80, debug=True) # Run Flask on port 80
              EOT
              # Install Gunicorn (a production-ready WSGI server)
              # Run the Flask app with Gunicorn
              # This command ensures the app keeps running even if you log out of SSH
              sudo yum install -y screen # Install screen to keep session alive
              screen -dmS flask_app_session bash -c "gunicorn --bind 0.0.0.0:80 app:app" # Run with Gunicorn on port 80
              EOF

  tags = {
    Name = "flask-app-instance"
  }
}

# Data source to dynamically fetch the latest Amazon Linux 2 AMI ID
data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Output the public IP address of the EC2 instance
# You can use this IP to access your Flask app from your browser.
output "instance_public_ip" {
  description = "The public IP address of the EC2 instance"
  value       = aws_instance.flask_app_instance.public_ip
}

# Define a variable for the AWS region
# This makes the region configurable without changing the provider block directly.
variable "aws_region" {
  description = "The AWS region to deploy resources in"
  type        = string
  default     = "us-east-1" # Make sure this matches your provider region.
}