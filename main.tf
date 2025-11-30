# Configure the AWS Provider
provider "aws" {
    region = "us-east-1"
}

# Data source to get the default VPC
data "aws_vpc" "default" {
  default = true
}

# Data source to get subnets in the default VPC
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Security Group for EC2 instances
resource "aws_security_group" "instance" {
  name = "terraform-example-instance-v2"

  ingress {
    from_port   = var.server_port
    to_port     = var.server_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Security Group for ALB
resource "aws_security_group" "alb_project" {
  name = "terraform-example-alb-v2"

  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]     #from anywhere
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"                 #All protocols
    cidr_blocks = ["0.0.0.0/0"]     #to anywhere
  }
}

# Launch Template
resource "aws_launch_template" "alb_project" {
  name_prefix   = "terraform-example-"
  image_id      = "ami-0fa3fe0fa7920f68e"
  instance_type = "t2.micro"

  vpc_security_group_ids = [aws_security_group.instance.id]

  user_data = base64encode(<<-EOF
            #!/bin/bash
            yum update -y
            yum install -y httpd
            echo "Hello, World" > /var/www/html/index.html
            systemctl start httpd
            systemctl enable httpd
            EOF
  )

  lifecycle {
    create_before_destroy = true
  }
}

# Auto Scaling Group
resource "aws_autoscaling_group" "alb_project" {
  launch_template {
    id      = aws_launch_template.alb_project.id
    version = "$Latest"
  }
  vpc_zone_identifier = data.aws_subnets.default.ids
  target_group_arns   = [aws_lb_target_group.asg.arn]
  health_check_type    = "ELB"

  min_size = 2
  max_size = 10

  tag {
    key                     = "name"
    value                   = "terraform-asg-example"
    propagate_at_launch     = true
  }
}

# Application Load Balancer
resource "aws_lb" "alb_project" {
  name                    = "terraform-asg-example"
  load_balancer_type      = "application"
  subnets                 = data.aws_subnets.default.ids
  security_groups         = [aws_security_group.alb_project.id]
}

# ALB Listener
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb_project.arn
  port              = 80
  protocol          = "HTTP"

  # By default, return a simple 404 page
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "404: page not found"
      status_code  = 404
    }
  }
}

# Target Group
resource "aws_lb_target_group" "asg" {
  name     = "terraform-asg-example"
  port     = var.server_port
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 3
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# ALB Listener Rule
resource "aws_lb_listener_rule" "asg" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  condition {
    path_pattern {
      values = ["*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.asg.arn
  }
}