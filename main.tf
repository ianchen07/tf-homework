provider "aws" {
  region                   = var.region
  shared_credentials_files = ["~/.aws/credentials"]
  profile                  = "default"
}


## Declare data
data "aws_vpc" "default_vpc" {
  default = true
}

data "aws_availability_zones" "available" {}

data "aws_subnet" "default_subnet_a" {
  vpc_id = data.aws_vpc.default_vpc.id

  filter {
    name   = "availability-zone"
    values = [data.aws_availability_zones.available.names[0]]
  }
}

data "aws_subnet" "default_subnet_b" {
  vpc_id = data.aws_vpc.default_vpc.id

  filter {
    name   = "availability-zone"
    values = [data.aws_availability_zones.available.names[1]]
  }
}

data "aws_iam_policy" "ECSTaskExecution" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}


## Create an ECS task execution role
resource "aws_iam_role" "ECSTaskExecutionRole" {
  name = "ian-tf-ECSTaskExecutionRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      },
    ]
  })
  managed_policy_arns = ["${data.aws_iam_policy.ECSTaskExecution.arn}"]
}

## create ECS Fargate cluster
resource "aws_ecs_cluster" "ecs_cluster" {
  name = var.cluster_name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  configuration {
    execute_command_configuration {
      logging = "DEFAULT"
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "fargate_provider" {
  cluster_name       = aws_ecs_cluster.ecs_cluster.name
  capacity_providers = ["FARGATE"]
}

## Create a log group
resource "aws_cloudwatch_log_group" "service_log_group" {
  name = "lg-${var.app_name}"
}

## Create task definition
resource "aws_ecs_task_definition" "task_definition" {
  family                   = "td-${var.app_name}"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.ECSTaskExecutionRole.arn
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512

  container_definitions = templatefile("containers/td.template.json",
    { CONTAINER_PORT = var.container_port,
      REGION         = var.region,
      LOG_GROUP      = aws_cloudwatch_log_group.service_log_group.name,
      APP_NAME       = var.app_name,
      IMAGE          = var.image_uri }
  )
}

## Create SGs
resource "aws_security_group" "alb_sg" {
  name        = "alb-sg"
  vpc_id      = data.aws_vpc.default_vpc.id
  description = "Only allow inbound from port 80 and 443 to ALB"

  ingress {
    protocol         = "tcp"
    from_port        = 80
    to_port          = 80
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    protocol         = "tcp"
    from_port        = 443
    to_port          = 443
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    protocol         = "-1"
    from_port        = 0
    to_port          = 0
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_security_group" "ecs_services_sg" {
  name        = "ecs-service-sg"
  vpc_id      = data.aws_vpc.default_vpc.id
  description = "Only allow inbound from ALB"

  ingress {
    protocol        = "tcp"
    from_port       = 80
    to_port         = 80
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

## Create ACM certificate
data "aws_route53_zone" "public" {
  name         = var.r53_zone
  private_zone = false
}

resource "aws_acm_certificate" "cert" {
  domain_name       = "${var.app_name}.${var.r53_zone}"
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  allow_overwrite = true
  name            = tolist(aws_acm_certificate.cert.domain_validation_options)[0].resource_record_name
  records         = [tolist(aws_acm_certificate.cert.domain_validation_options)[0].resource_record_value]
  type            = tolist(aws_acm_certificate.cert.domain_validation_options)[0].resource_record_type
  zone_id         = data.aws_route53_zone.public.id
  ttl             = 60
}

resource "aws_acm_certificate_validation" "validate" {
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [aws_route53_record.cert_validation.fqdn]
}

## Create load balancing resources ( enable https over http )
resource "aws_lb" "lb" {
  name               = "ian-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [data.aws_subnet.default_subnet_a.id, data.aws_subnet.default_subnet_b.id]
}

resource "aws_alb_target_group" "target_group" {
  name        = "tg-${var.app_name}"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default_vpc.id
  target_type = "ip"

  health_check {
    healthy_threshold   = "3"
    interval            = "30"
    protocol            = "HTTP"
    matcher             = "200"
    timeout             = "3"
    path                = "/"
    unhealthy_threshold = "2"
  }
}

resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"

    }
  }
}

resource "aws_lb_listener" "https_listener" {
  load_balancer_arn = aws_lb.lb.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = aws_acm_certificate.cert.arn

  default_action {
    target_group_arn = aws_alb_target_group.target_group.id
    type             = "forward"
  }
}

## Create service
resource "aws_ecs_service" "ecs_service" {
  name                               = "svc-${var.app_name}"
  cluster                            = aws_ecs_cluster.ecs_cluster.id
  task_definition                    = aws_ecs_task_definition.task_definition.arn
  desired_count                      = 1
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200
  launch_type                        = "FARGATE"
  scheduling_strategy                = "REPLICA"

  network_configuration {
    security_groups  = [aws_security_group.ecs_services_sg.id]
    subnets          = [data.aws_subnet.default_subnet_a.id, data.aws_subnet.default_subnet_b.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_alb_target_group.target_group.arn
    container_name   = var.app_name
    container_port   = var.container_port
  }
}

## Create R53 record
resource "aws_route53_record" "app_dns" {
  zone_id = data.aws_route53_zone.public.zone_id
  name    = "${var.app_name}.${var.r53_zone}"
  type    = "A"
  alias {
    name                   = aws_lb.lb.dns_name
    zone_id                = aws_lb.lb.zone_id
    evaluate_target_health = false
  }
}
