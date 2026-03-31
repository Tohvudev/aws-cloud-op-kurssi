# THIS IS A WORK IN PROGRESS TERRAFORM MAIN.TF FILE AND MIGHT GET EDITED IN THE FUTURE. NOT INTENDED FOR PRODUCTION, ONLY A PROOF-OF-CONCEPT
# USER DATA FAILS FOR NOW AND WILL BE DELETED OR FIXED IN THE FUTURE. IT CONTAINS DUPLICATES.


provider "aws" {
  region = "us-east-1"
}

# Grab the default VPC since we aren't building a custom network for this POC
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "all" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Open 80 for the ALB and 22 so we can debug if the user_data fails
resource "aws_security_group" "web_sg" {
  name        = "canary-test-sg"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# v1: Stable environment
resource "aws_instance" "v1" {
  ami                  = "ami-0c3389a4fa5bddaad"
  instance_type        = "t2.micro"
  iam_instance_profile = "LabInstanceProfile"
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  # Simple flask bootstrap
  user_data = <<-EOF
    #!/bin/bash
    dnf update -y
    dnf install -y python3-pip
    pip3 install flask
    cat << 'PY' > /home/ec2-user/app.py
from flask import Flask
app = Flask(__name__)
@app.route('/')
def home():
    return '<h1>v1.0 - Stable</h1>'
if __name__ == '__main__':
    app.run(host='0.0.0.0', port=80)
PY
    sudo python3 /home/ec2-user/app.py > /home/ec2-user/app.log 2>&1 &
  EOF

  tags = { Name = "web-v1" }
}

# v2: Canary environment (returns 500 to simulate failure/testing)
resource "aws_instance" "v2" {
  ami                  = "ami-0c3389a4fa5bddaad"
  instance_type        = "t2.micro"
  iam_instance_profile = "LabInstanceProfile"
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  user_data = <<-EOF
    #!/bin/bash
    dnf update -y
    dnf install -y python3-pip
    pip3 install flask
    cat << 'PY' > /home/ec2-user/app.py
from flask import Flask
app = Flask(__name__)
@app.route('/')
def home():
    return '<h1>v2.0 - Canary</h1>', 500
if __name__ == '__main__':
    app.run(host='0.0.0.0', port=80)
PY
    sudo python3 /home/ec2-user/app.py > /home/ec2-user/app.log 2>&1 &
  EOF

  tags = { Name = "web-v2" }
}

# Target groups for the 90/10 split logic
resource "aws_lb_target_group" "v1_tg" {
  name     = "v1-tg"
  port     = 80
}

# Open 80 for the ALB and 22 so we can debug if the user_data fails
resource "aws_security_group" "web_sg" {
  name        = "canary-test-sg"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# v1: Stable environment
resource "aws_instance" "v1" {
  ami                  = "ami-0c3389a4fa5bddaad"
  instance_type        = "t2.micro"
  iam_instance_profile = "LabInstanceProfile"
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  # Simple flask bootstrap
  user_data = <<-EOF
    #!/bin/bash
    dnf update -y
    dnf install -y python3-pip
    pip3 install flask
    cat << 'PY' > /home/ec2-user/app.py
from flask import Flask
app = Flask(__name__)
@app.route('/')
def home():
    return '<h1>v1.0 - Stable</h1>'
if __name__ == '__main__':
    app.run(host='0.0.0.0', port=80)
PY
    sudo python3 /home/ec2-user/app.py > /home/ec2-user/app.log 2>&1 &
  EOF

  tags = { Name = "web-v1" }
}

# v2: Canary environment (returns 500 to simulate failure/testing)
resource "aws_instance" "v2" {
  ami                  = "ami-0c3389a4fa5bddaad"
  instance_type        = "t2.micro"
  iam_instance_profile = "LabInstanceProfile"
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  user_data = <<-EOF
    #!/bin/bash
    dnf update -y
    dnf install -y python3-pip
    pip3 install flask
    cat << 'PY' > /home/ec2-user/app.py
from flask import Flask
app = Flask(__name__)
@app.route('/')
def home():
    return '<h1>v2.0 - Canary</h1>', 500
if __name__ == '__main__':
    app.run(host='0.0.0.0', port=80)
PY
    sudo python3 /home/ec2-user/app.py > /home/ec2-user/app.log 2>&1 &
  EOF

  tags = { Name = "web-v2" }
}

# Target groups for the 90/10 split logic
resource "aws_lb_target_group" "v1_tg" {
  name     = "v1-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id
  health_check { path = "/" }
}

resource "aws_lb_target_group" "v2_tg" {
  name     = "v2-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id
  health_check { path = "/" }
}

resource "aws_lb_target_group_attachment" "v1_attach" {
  target_group_arn = aws_lb_target_group.v1_tg.arn
  target_id        = aws_instance.v1.id
}

resource "aws_lb_target_group_attachment" "v2_attach" {
  target_group_arn = aws_lb_target_group.v2_tg.arn
  target_id        = aws_instance.v2.id
}

# Public ALB
resource "aws_lb" "main_alb" {
  name               = "web-app-lb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web_sg.id]
  subnets            = data.aws_subnets.all.ids
}

# Weighted routing: 90% to stable, 10% to canary
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "forward"
    forward {
      target_group {
        arn    = aws_lb_target_group.v1_tg.arn
        weight = 90
      }
      target_group {
        arn    = aws_lb_target_group.v2_tg.arn
        weight = 10
      }
    }
  }
}

output "alb_url" {
  value = "http://${aws_lb.main_alb.dns_name}"
}
