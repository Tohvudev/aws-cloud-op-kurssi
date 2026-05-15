
/* Provider and Locals tells Terraform that it should use AWS as the cloud provider and defies a set of
reusable variables */

provider "aws" {
  region = "us-east-1"
}

locals {
  common_tags = {
    Project     = "aws-canary-warning"
    Environment = "Production"
    ManagedBy   = "Terraform"
  }
}

/* Uploads our SSH publix key to AWS so it can be attached to EC2 instances
this key is used to SSH into the Canary. The stable one uses a different technique*/

resource "aws_key_pair" "deployer" {
  key_name   = "canary-deployer-key-v5"
  public_key = file("./my-key.pub")
}

/* NETWORK These are the network settings */

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "all" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

/* SECURITY*/

resource "aws_security_group" "web_sg" {
  name        = "canary-sg-v5"
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

/* This is the stable environment with the ASG and the automated script runner SSM */

#  STABLE ENVIRONMENT (v1)
resource "aws_launch_template" "v1_template" {
  name_prefix   = "v1-stable-"
  image_id      = "ami-0c3389a4fa5bddaad"
  instance_type = "t2.micro"
  key_name      = aws_key_pair.deployer.key_name

  iam_instance_profile {
    name = "LabInstanceProfile"
  }

  vpc_security_group_ids = [aws_security_group.web_sg.id]

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, { Name = "web-v1-asg" })
  }
}

resource "aws_autoscaling_group" "v1_asg" {
  desired_capacity    = 1
  max_size            = 2
  min_size            = 1
  vpc_zone_identifier = data.aws_subnets.all.ids
  target_group_arns   = [aws_lb_target_group.v1_tg.arn]
  launch_template {
    id      = aws_launch_template.v1_template.id
    version = "$Latest"
  }
}

resource "aws_ssm_association" "v1_config" {
  name = "AWS-RunShellScript"
  targets {
    key    = "tag:Name"
    values = ["web-v1-asg"]
  }
  parameters = {
    commands = join("\n", [
      "sudo dnf install -y python3-pip amazon-cloudwatch-agent",
      "sudo pip3 install flask",
      "cat << 'CW' > /tmp/cw-config.json",
      "{\"metrics\":{\"metrics_collected\":{\"mem\":{\"measurement\":[\"mem_used_percent\"]}}},\"logs\":{\"logs_collected\":{\"files\":{\"collect_list\":[{\"file_path\":\"/home/ec2-user/app.log\",\"log_group_name\":\"/aws/ec2/stable-v1\",\"log_stream_name\":\"{instance_id}\"}]}}}}",
      "CW",
      "sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/tmp/cw-config.json",
      "cat << 'PY' > /home/ec2-user/app.py",
      "from flask import Flask",
      "app = Flask(__name__)",
      "@app.route('/health')",
      "def health(): return 'OK', 200",
      "@app.route('/')",
      "def home(): return '<h1>v1.0 - Stable</h1><p>Hey.. Im Working here!</p>'",
      "if __name__ == '__main__': app.run(host='0.0.0.0', port=80)",
      "PY",
      "nohup sudo python3 /home/ec2-user/app.py > /home/ec2-user/app.log 2>&1 &"
    ])
  }
}

/* This is the broken canary one and it uses the remote-exec and the private key to log into the instance*/

#  CANARY ENVIRONMENT (v2)
resource "aws_instance" "v2" {
  ami                    = "ami-0c3389a4fa5bddaad"
  instance_type          = "t2.micro"
  key_name               = aws_key_pair.deployer.key_name
  iam_instance_profile   = "LabInstanceProfile"
  vpc_security_group_ids = [aws_security_group.web_sg.id]
  subnet_id              = data.aws_subnets.all.ids[0]

  connection {
    type        = "ssh"
    user        = "ec2-user"
    private_key = file("./my-key")
    host        = self.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "sudo dnf install -y python3-pip amazon-cloudwatch-agent",
      "sudo pip3 install flask",
      "cat << 'CW' > /tmp/cw-config.json",
      "{\"metrics\":{\"metrics_collected\":{\"mem\":{\"measurement\":[\"mem_used_percent\"]}}},\"logs\":{\"logs_collected\":{\"files\":{\"collect_list\":[{\"file_path\":\"/home/ec2-user/app.log\",\"log_group_name\":\"/aws/ec2/canary-v2\",\"log_stream_name\":\"{instance_id}\"}]}}}}",
      "CW",
      "sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/tmp/cw-config.json",
      "cat << 'PY' > /home/ec2-user/app.py",
      "from flask import Flask",
      "app = Flask(__name__)",
      "@app.route('/health')",
      "def health(): return 'OK', 200",
      "@app.route('/')",
      "def warning(): return '<h1>400 Warning</h1><p>Im activating alarms. Watch me..</p>', 400",
      "if __name__ == '__main__': app.run(host='0.0.0.0', port=80)",
      "PY",
      "nohup sudo python3 /home/ec2-user/app.py > /home/ec2-user/app.log 2>&1 &",
      "sleep 5"
    ]
  }

  tags = merge(local.common_tags, { Name = "web-v2-canary" })
}

/* This creates an Application Load Balancer and defines rules to where to send the traffic
With this we have a single URL and we get two apps shown over it via the 90/10 split we set up */

#  LOAD BALANCING
resource "aws_lb_target_group" "v1_tg" {
  name     = "v1-tg-stable"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id
  health_check {
    path = "/health"
  }
}

resource "aws_lb_target_group" "v2_tg" {
  name     = "v2-tg-400"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id
  health_check {
    path = "/health"
  }
}

resource "aws_lb_target_group_attachment" "v2_attach" {
  target_group_arn = aws_lb_target_group.v2_tg.arn
  target_id        = aws_instance.v2.id
}

resource "aws_lb" "main" {
  name               = "canary-lb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web_sg.id]
  subnets            = data.aws_subnets.all.ids
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
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

/* These are the alerts and notifications. It sets up the SNS, subscribes to emails and creates triggers for Cloudwatch
this uses the provided endpoint email to send messages to. 400 Alarm watches the load balancer and if someone hits the
10% canary site it alarms. Instance failure alarm is when the instance goes down. It also has the ASG alarms that
inform about autoscaling events */

# ALERTS & NOTIFICATIONS
resource "aws_sns_topic" "alerts" {
  name = "canary-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = "YOUR EMAIL HERE"    # CHANGE THIS TO YOUR EMAIL TO GET THE MESSAGES
}

resource "aws_sns_topic_policy" "asg_publish" {
  arn = aws_sns_topic.alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "autoscaling.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.alerts.arn
    }]
  })
}

resource "aws_autoscaling_notification" "asg_notifications" {
  group_names = [aws_autoscaling_group.v1_asg.name]
  topic_arn   = aws_sns_topic.alerts.arn
  notifications = [
    "autoscaling:EC2_INSTANCE_TERMINATE",
    "autoscaling:EC2_INSTANCE_LAUNCH",
    "autoscaling:EC2_INSTANCE_LAUNCH_ERROR"
  ]
}

resource "aws_cloudwatch_metric_alarm" "warning_400" {
  alarm_name          = "Canary-400-Warning"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "HTTPCode_Target_4XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = "60"
  statistic           = "Sum"
  threshold           = "0"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "self_healing" {
  alarm_name          = "Canary-Instance-Failure"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = "60"
  statistic           = "Maximum"
  threshold           = "0"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    InstanceId = aws_instance.v2.id
  }
}

output "url" {
  value = "http://${aws_lb.main.dns_name}"
}
