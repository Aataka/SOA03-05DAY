terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = var.region
}

# ---------------------------------------------------------------------------
# Lookups: default VPC + one default subnet + latest AL2023 AMI
# ---------------------------------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# IAM: SSM (no SSH) + X-Ray write & sampling reads
#   AWSXRayDaemonWriteAccess covers PutTraceSegments/PutTelemetryRecords AND
#   GetSamplingRules/GetSamplingTargets (needed by the SDK's central sampling).
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name_prefix        = "${var.name_prefix}-role-"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "xray" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_instance_profile" "ec2" {
  name_prefix = "${var.name_prefix}-prof-"
  role        = aws_iam_role.ec2.name
}

# ---------------------------------------------------------------------------
# Security group: egress-only. Load/spoof is driven from INSIDE via SSM
# (curl localhost), so no inbound is needed -> instance stays private.
# ---------------------------------------------------------------------------
resource "aws_security_group" "ec2" {
  name_prefix = "${var.name_prefix}-sg-"
  description = "egress only; app driven via SSM curl localhost"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "all egress (X-Ray endpoint, yum, pip)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# EC2: instrumented Flask + X-Ray daemon (user_data)
# ---------------------------------------------------------------------------
locals {
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    region            = var.region
    auto_stop_minutes = var.auto_stop_minutes
  })
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = element(data.aws_subnets.default.ids, 0)
  vpc_security_group_ids = [aws_security_group.ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  user_data              = local.user_data

  metadata_options {
    http_tokens   = "required" # IMDSv2 only
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size           = 8
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  tags = {
    Name = "${var.name_prefix}-app"
  }
}

# ---------------------------------------------------------------------------
# X-Ray group -> publishes CloudWatch metrics (AWS/X-Ray) per GroupName.
# We alarm on the group's fault rate for hypothesis C.
# ---------------------------------------------------------------------------
resource "aws_xray_group" "todo" {
  group_name        = "${var.name_prefix}-group"
  filter_expression = "service(\"WebTier\") OR service(\"AppTier\")"

  insights_configuration {
    insights_enabled      = true
    notifications_enabled = false
  }
}

# ---------------------------------------------------------------------------
# SNS (optional) for alarm notifications. Email confirm is manual.
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "alarms" {
  name_prefix = "${var.name_prefix}-"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ---------------------------------------------------------------------------
# Hypothesis C (pivot): X-Ray groups publish ONLY ApproximateTraceCount to
# CloudWatch -- there is NO FaultRate metric. So to alarm on faults we make a
# second group whose filter_expression keeps only fault traces; that group's
# ApproximateTraceCount == number of fault traces. Alarm on >= 1.
# ---------------------------------------------------------------------------
resource "aws_xray_group" "faults" {
  group_name        = "${var.name_prefix}-faults"
  filter_expression = "fault = true"

  insights_configuration {
    insights_enabled      = false
    notifications_enabled = false
  }
}

resource "aws_cloudwatch_metric_alarm" "fault_rate" {
  alarm_name          = "${var.name_prefix}-fault-rate"
  alarm_description   = "fault-filtered X-Ray group has >=1 trace (5xx surfaced via traces)"
  namespace           = "AWS/X-Ray"
  metric_name         = "ApproximateTraceCount"
  dimensions          = { GroupName = aws_xray_group.faults.group_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}
