// Configure the AWS provider for the target region using the local demo profile.
provider "aws" {
  region  = var.region
  profile = "demo"
}

// Required deployment inputs.
variable "region" {
  type = string
}
variable "ami" {
  type = string
}

// Discover AZs dynamically so subnets can be spread across the active region.
data "aws_availability_zones" "available" {
  state = "available"
}

// Core network: one VPC with DNS support enabled for internal service discovery.
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "main-vpc"
  }
  enable_dns_hostnames = true
  enable_dns_support   = true
}

resource "aws_subnet" "public" {
  count = length(data.aws_availability_zones.available.names)

  // Create one public subnet per availability zone.
  cidr_block        = "10.0.${count.index + 1}.0/24"
  vpc_id            = aws_vpc.main.id
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "public-${count.index + 1}"
  }
}

resource "aws_subnet" "private" {
  count = length(data.aws_availability_zones.available.names)

  // Create one private subnet per availability zone for database placement.
  cidr_block        = "10.0.${count.index + 4}.0/24"
  vpc_id            = aws_vpc.main.id
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "private-${count.index + 1}"
  }
}

// Internet access for public-facing resources such as the load balancer and EC2 instances.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "main-igw"
  }
}

// Route tables split public internet-routable traffic from private-only subnets.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "public-route-table"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "private-route-table"
  }
}

// Default route for public subnets to reach the internet through the IGW.
resource "aws_route" "public" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

// Attach every generated subnet to the matching route table.
resource "aws_route_table_association" "public" {
  count          = length(data.aws_availability_zones.available.names)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(data.aws_availability_zones.available.names)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

// Application instances accept traffic only from the ALB on the app port.
resource "aws_security_group" "instance" {
  name_prefix = "instance-sg"
  vpc_id      = aws_vpc.main.id

  // Uncomment if direct SSH access is required for debugging.
  # ingress {
  #   from_port   = 22
  #   to_port     = 22
  #   protocol    = "tcp"
  #   cidr_blocks = ["0.0.0.0/0"]
  # }

  ingress {
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.load_balancer_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "all"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "application-sg"
  }
}



resource "aws_security_group" "load_balancer_sg" {
  name_prefix = "lb-sg"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "all"
    cidr_blocks = ["0.0.0.0/0"]
  }


  tags = {
    Name = "load-balancer-sg"
  }
}


// Restrict PostgreSQL access so only the application tier can reach the database.
resource "aws_security_group" "db" {
  name_prefix = "db-sg"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.instance.id]
  }

  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "all"
    security_groups = [aws_security_group.instance.id]
  }

  tags = {
    Name = "db-sg"
  }
}

// Bootstrap the application AMI with runtime values generated during provisioning.
data "template_file" "user_data" {

  template = <<EOF

#!/bin/bash
sudo chown ec2-user:ec2-user /home/ec2-user/scripts/webApp/*
cd /home/ec2-user/scripts/webApp/config
sudo sed -i 's/"localhost"/"${aws_db_instance.rds_instance.endpoint}"/g' config.json
sudo sed -i 's/:5432//' config.json
cd /home/ec2-user/scripts/webApp/seeders
sudo sed -i 's/process.env.AWS_S3_BUCKET_NAME/"${aws_s3_bucket.my_bucket.bucket}"/g' app.js

EOF

}

resource "aws_launch_template" "lt" {
  name                    = "asg_launch_config"
  image_id                = var.ami
  instance_type           = "t2.micro"
  key_name                = "SG"
  disable_api_termination = false

  network_interfaces {
    // The launch template pins the primary interface to the first public subnet.
    associate_public_ip_address = true
    security_groups             = [aws_security_group.instance.id]
    subnet_id                   = aws_subnet.public[0].id
  }

  user_data = base64encode(data.template_file.user_data.rendered)

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_instance_profile.name
  }

  placement {
    // Keep placement aligned with the subnet chosen above.
    availability_zone = data.aws_availability_zones.available.names[0]
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      // Encrypt the instance root volume with the customer-managed EBS KMS key.
      delete_on_termination = true
      volume_size           = 50
      volume_type           = "gp2"
      kms_key_id            = aws_kms_key.ebs_key.arn
      encrypted             = true
    }
  }

  tags = {
    Name = "Terraform_Managed_Custom_AMI_Instance"
  }
}

# Legacy single-instance configuration kept for reference after the move to an ASG.
# resource "aws_instance" "Terraform_Managed" {
#   ami                         = var.ami
#   instance_type               = "t2.micro"
#   key_name                    = "SG"
#   subnet_id                   = aws_subnet.public[0].id
#   vpc_security_group_ids      = [aws_security_group.instance.id]
#   associate_public_ip_address = true # enable public IP and DNS for the instance
#   disable_api_termination     = false
#   user_data                   = <<EOF
# #!/bin/bash
# sudo chown ec2-user:ec2-user /home/ec2-user/scripts/webApp/*
# cd /home/ec2-user/scripts/webApp/config
# sudo sed -i 's/"localhost"/"${aws_db_instance.rds_instance.endpoint}"/g' config.json
# sudo sed -i 's/:5432//' config.json
# cd /home/ec2-user/scripts/webApp/seeders
# sudo sed -i 's/process.env.AWS_S3_BUCKET_NAME/"${aws_s3_bucket.my_bucket.bucket}"/g' app.js

# EOF

#   root_block_device {
#     volume_size           = 50 # root volume size in GB
#     delete_on_termination = true
#   }
#   tags = {
#     Name = "Terraform_Managed_Custom_AMI_Instance"
#   }

#   count = 1

#   lifecycle {
#     ignore_changes = [subnet_id]
#   }

#   availability_zone    = data.aws_availability_zones.available.names[0]
#   iam_instance_profile = aws_iam_instance_profile.ec2_instance_profile.name
# }


// The ASG keeps at least one instance available and registers instances with the ALB target group.
resource "aws_autoscaling_group" "autoscaling" {

  name                      = "csye6225-asg-spring2023"
  vpc_zone_identifier       = [for subnet in aws_subnet.public : subnet.id]
  max_size                  = 3
  min_size                  = 1
  health_check_grace_period = 30
  health_check_type         = "EC2"
  force_delete              = true
  default_cooldown          = 60

  launch_template {
    id = aws_launch_template.lt.id
    // Always use the newest launch template revision when instances are refreshed.
    version = "$Latest"
  }


  target_group_arns = [aws_lb_target_group.target_group.arn]

  tag {
    key                 = "Key"
    value               = "Value"
    propagate_at_launch = true
  }
}

// IAM identity attached to EC2 so the app can access S3 and CloudWatch without static credentials.
resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "EC2-CSYE6225-Instance-Profile"

  role = aws_iam_role.ec2_csye6225_role.name
}

resource "aws_iam_role" "ec2_csye6225_role" {
  name = "EC2-CSYE6225"

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
    Name = "EC2-CSYE6225-Role"
  }
}

resource "aws_iam_role_policy_attachment" "webapp_s3_policy_attachment" {
  policy_arn = aws_iam_policy.webapp_s3_policy.arn
  role       = aws_iam_role.ec2_csye6225_role.name
}

// Managed policy for the CloudWatch agent running on the EC2 instances.
resource "aws_iam_role_policy_attachment" "cloudwatch_agent_policy_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  role       = aws_iam_role.ec2_csye6225_role.name
}

// Generate a globally unique suffix because S3 bucket names must be unique across AWS.
resource "random_pet" "bucket_name" {
  length    = 2
  separator = "-"
}

// Application asset bucket with encryption and lifecycle management enabled.
resource "aws_s3_bucket" "my_bucket" {
  bucket        = "my-${random_pet.bucket_name.id}-bucket"
  force_destroy = true

  tags = {
    Environment = "Production"
  }
}


// Expose the generated bucket name for application and deployment use.
output "bucket_name" {
  value = aws_s3_bucket.my_bucket.bucket
}

// Enable default server-side encryption on the bucket.
resource "aws_s3_bucket_server_side_encryption_configuration" "aws_s3_encrypt" {
  bucket = "my-${random_pet.bucket_name.id}-bucket"

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}


// Transition older objects to a cheaper storage tier after 30 days.
resource "aws_s3_bucket_lifecycle_configuration" "private_bucket_lifecycle" {
  bucket = "my-${random_pet.bucket_name.id}-bucket"
  rule {
    id     = "transition-to-ia"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
  }
}



// Deny insecure transport so objects are only accessed over HTTPS.
resource "aws_s3_bucket_policy" "private_bucket_policy" {
  bucket = "my-${random_pet.bucket_name.id}-bucket"
  depends_on = [
    //  aws_s3_bucket_acl.s3_bucket_acl,
    random_pet.bucket_name,
    aws_s3_bucket.my_bucket
  ]


  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyPublicAccess",
        Effect    = "Deny",
        Principal = "*",
        Action    = "s3:GetObject",
        Resource = [
          "arn:aws:s3:::my-${random_pet.bucket_name.id}-bucket/*"
        ],
        Condition = {
          Bool = {
            "aws:SecureTransport" : "false"
          }
        }
      }
    ]
  })

}

resource "aws_s3_bucket_public_access_block" "my_bucket_public_access_block" {
  bucket = "my-${random_pet.bucket_name.id}-bucket"

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}


// Parameter group placeholder for PostgreSQL-specific engine settings.
resource "aws_db_parameter_group" "postgres_params" {
  name_prefix = "csye6225-postgres-params"
  family      = "postgres13"
}

// Application policy covering S3 object access plus CloudWatch metrics and logs.
resource "aws_iam_policy" "webapp_s3_policy" {
  name = "WebAppS3"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "cloudwatch:PutMetricData",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics"
        ]
        Effect = "Allow"
        Resource = [
          "arn:aws:s3:::my-${random_pet.bucket_name.id}-bucket",
          "arn:aws:s3:::my-${random_pet.bucket_name.id}-bucket/*",
        ]
  })
}


// RDS stays isolated in the private subnets.
resource "aws_db_subnet_group" "private_rds_subnet_group" {
  name        = "private-rds-subnet-group"
  description = "Private subnet group for RDS instances"
  subnet_ids  = aws_subnet.private.*.id
}


// Customer-managed KMS key used to encrypt the PostgreSQL instance.
resource "aws_kms_key" "rds_encryption_key" {
  description             = "Customer-managed encryption key for RDS instances"
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "key-policy"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action = [
          "kms:*"
        ]
        Resource = "*"
      },
      {
        Sid    = "Allow access to RDS resource"
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name = "RDS Encryption Key"
  }
}

// Stable alias for the RDS encryption key.
resource "aws_kms_alias" "rds_encryption_key" {
  name          = "alias/RDS_KEY"
  target_key_id = aws_kms_key.rds_encryption_key.id
}





// Look up the current account so the Auto Scaling service-linked role can administer the key.
data "aws_caller_identity" "current" {}

// Customer-managed KMS key used for EC2 root volume encryption.
resource "aws_kms_key" "ebs_key" {
  description             = "Customer-managed encryption key for EBS instances"
  deletion_window_in_days = 7
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action = [
          "kms:*"
        ]
        Resource = "*"
      },
      {
        Sid    = "Allow administration of the key"
        Effect = "Allow"
        Principal = {
          AWS = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"]
        }
        Action = [
          "kms:Create*",
          "kms:Describe*",
          "kms:Enable*",
          "kms:List*",
          "kms:Put*",
          "kms:Update*",
          "kms:Revoke*",
          "kms:Disable*",
          "kms:Get*",
          "kms:Delete*",
          "kms:TagResource",
          "kms:UntagResource",
          "kms:ScheduleKeyDeletion",
          "kms:CancelKeyDeletion"
        ]
        Resource = "*"
      },
      {
        Sid    = "Allow use of the key for EBS encryption"
        Effect = "Allow"
        Principal = {
          Service = ["ec2.amazonaws.com"]
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })
  tags = {
    Name = "EBS_Encryption_Key"
  }
}

// Stable alias for the EBS encryption key.
resource "aws_kms_alias" "ebs_key" {
  name          = "alias/EBS_KEY"
  target_key_id = aws_kms_key.ebs_key.id
}

// PostgreSQL instance for the application, deployed privately and encrypted at rest.
resource "aws_db_instance" "rds_instance" {
  identifier             = "csye6225"
  allocated_storage      = 20
  engine                 = "postgres"
  engine_version         = "13.3"
  instance_class         = "db.t3.micro"
  db_name                = "csye6225"
  username               = "csye6225"
  password               = "redhat1234"
  skip_final_snapshot    = true
  publicly_accessible    = false
  vpc_security_group_ids = [aws_security_group.db.id]
  db_subnet_group_name   = aws_db_subnet_group.private_rds_subnet_group.name
  parameter_group_name   = aws_db_parameter_group.postgres_params.name
  kms_key_id             = aws_kms_key.rds_encryption_key.arn
  storage_encrypted      = true


}

// Export the resolved database endpoint for downstream use.
output "rds_endpoint" {
  value = aws_db_instance.rds_instance.endpoint
}

// Domain used for Route 53 resolution and ACM certificate lookup.
variable "domain_name" {
  type = string
}

// Internet-facing application load balancer spanning the first three public subnets.
resource "aws_lb" "load_balancer" {
  name               = "web-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.load_balancer_sg.id]
  subnets            = [aws_subnet.public[0].id, aws_subnet.public[1].id, aws_subnet.public[2].id]
  tags = {
    Environment = "prod"
  }
}

// Export the ALB DNS name for verification and DNS troubleshooting.
output "load_balancer_dns_name" {
  value = aws_lb.load_balancer.dns_name
}

// Resolve the hosted zone matching the requested application domain.
data "aws_route53_zone" "main" {
  name = var.domain_name

}

// HTTPS listener terminates TLS at the ALB and forwards traffic to the target group.
resource "aws_lb_listener" "lb_listener" {

  load_balancer_arn = aws_lb.load_balancer.arn
  port              = "443"
  protocol          = "HTTPS"
  certificate_arn   = data.aws_acm_certificate.aws_acm_certificate.arn

  // Forward validated HTTPS traffic to the application instances.
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.target_group.arn
  }

}


// Register EC2 instances and health check the application on /healthz.
resource "aws_lb_target_group" "target_group" {
  name        = "web-tg"
  port        = 5000
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.main.id
  health_check {
    interval            = 300
    path                = "/healthz"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 2
    port                = 5000
  }


}

// Publish the public application DNS record as an alias to the ALB.
resource "aws_route53_record" "web" {
  name    = var.domain_name
  type    = "A"
  zone_id = data.aws_route53_zone.main.zone_id

  alias {
    name                   = aws_lb.load_balancer.dns_name
    zone_id                = aws_lb.load_balancer.zone_id
    evaluate_target_health = true
  }
}

// Scale out when average ASG CPU stays above the configured threshold.
resource "aws_cloudwatch_metric_alarm" "scaleuppolicyalarm" {
  alarm_name          = "scaleuppolicyalarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 5

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.autoscaling.name
  }

  alarm_description = "ec2 cpu utilization monitoring"
  alarm_actions     = [aws_autoscaling_policy.upautoscaling_policy.arn]
}


// Scale in when average ASG CPU drops below the configured threshold.
resource "aws_cloudwatch_metric_alarm" "scaledownpolicyalarm" {
  alarm_name          = "scaledownpolicyalarm"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 3

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.autoscaling.name
  }

  alarm_description = "ec2 cpu utilization monitoring"
  alarm_actions     = [aws_autoscaling_policy.downautoscaling_policy.arn]
}

// Add capacity when the scale-up alarm fires.
resource "aws_autoscaling_policy" "upautoscaling_policy" {
  name                   = "upautoscaling_policy"
  scaling_adjustment     = 1
  adjustment_type        = "PercentChangeInCapacity"
  cooldown               = 60
  autoscaling_group_name = aws_autoscaling_group.autoscaling.name
}

// Remove capacity when the scale-down alarm fires.
resource "aws_autoscaling_policy" "downautoscaling_policy" {
  name                   = "downautoscaling_policy"
  scaling_adjustment     = -1
  adjustment_type        = "PercentChangeInCapacity"
  cooldown               = 60
  autoscaling_group_name = aws_autoscaling_group.autoscaling.name
}

// Central log group for application or agent logs created by the stack.
resource "aws_cloudwatch_log_group" "csye6225-spring2023" {
  name = "csye6225-spring2023"
}

// Reuse an already-issued ACM certificate for the application domain.
data "aws_acm_certificate" "aws_acm_certificate" {
  domain   = var.domain_name
  statuses = ["ISSUED"]
}