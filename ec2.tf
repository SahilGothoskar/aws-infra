provider "aws" {
  region  = var.region
  profile = "demo"
}

variable "region" {
  type = string
}
variable "ami" {
  type = string
}

data "aws_availability_zones" "available" {
  state = "available"
}

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

  cidr_block        = "10.0.${count.index + 1}.0/24"
  vpc_id            = aws_vpc.main.id
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "public-${count.index + 1}"
  }
}

resource "aws_subnet" "private" {
  count = length(data.aws_availability_zones.available.names)

  cidr_block        = "10.0.${count.index + 4}.0/24"
  vpc_id            = aws_vpc.main.id
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "private-${count.index + 1}"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "main-igw"
  }
}

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

resource "aws_route" "public" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

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

resource "aws_security_group" "instance" {
  name_prefix = "instance-sg"
  vpc_id      = aws_vpc.main.id

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


resource "aws_security_group" "db" {
  name_prefix = "db-sg"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.instance.id]
  }

  # ingress {
  #   from_port   = 22
  #   to_port     = 22
  #   protocol    = "tcp"
  #   cidr_blocks = ["10.0.0.0/8"] # Restrict SSH access to VPC CIDR range
  # }

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
    associate_public_ip_address = true
    security_groups             = [aws_security_group.instance.id]
    subnet_id                   = aws_subnet.public[0].id
  }

  user_data = base64encode(data.template_file.user_data.rendered)

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_instance_profile.name
  }

  placement {
    availability_zone = data.aws_availability_zones.available.names[0]
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
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
    //version = aws_launch_template.lt.latest_version
    version = "$Latest"
  }


  target_group_arns = [aws_lb_target_group.target_group.arn]

  tag {
    key                 = "Key"
    value               = "Value"
    propagate_at_launch = true
  }
}

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

#Assignment07_Code


resource "aws_iam_role_policy_attachment" "cloudwatch_agent_policy_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  role       = aws_iam_role.ec2_csye6225_role.name
}

## Assignment07 Code


#Note the addition of the count parameter to ensure that only one instance is created, as well as the use of the data.aws_availability_zones data source to retrieve the list of available availability zones for the selected region, and the use of the [0] index to ensure that the instance is launched in the first available zone. The lifecycle block with the ignore_changes parameter is also added to prevent changes to the subnet ID from triggering the creation of a new instance.


resource "random_pet" "bucket_name" {
  length    = 2
  separator = "-"
}

resource "aws_s3_bucket" "my_bucket" {
  bucket        = "my-${random_pet.bucket_name.id}-bucket"
  force_destroy = true

  tags = {
    Environment = "Production"
  }
}


output "bucket_name" {
  value = aws_s3_bucket.my_bucket.bucket
}
# resource "aws_s3_bucket_acl" "s3_bucket_acl" {
#   bucket = "my-${random_pet.bucket_name.id}-bucket"
#   acl    = "private"

# }


resource "aws_s3_bucket_server_side_encryption_configuration" "aws_s3_encrypt" {
  bucket = "my-${random_pet.bucket_name.id}-bucket"

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}


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


# Configure the PostgreSQL parameter group
resource "aws_db_parameter_group" "postgres_params" {
  name_prefix = "csye6225-postgres-params"
  family      = "postgres13"
}

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
      },
    ]
  })
}


resource "aws_db_subnet_group" "private_rds_subnet_group" {
  name        = "private-rds-subnet-group"
  description = "Private subnet group for RDS instances"
  subnet_ids  = aws_subnet.private.*.id
}

#  resource "aws_kms_key" "rds_encryption_key" {
#    description             = "Customer-managed encryption key for RDS instances"
#    deletion_window_in_days = 7
# policy = jsonencode({
#   Version = "2012-10-17"
#   Statement = [
#     {
#       Effect = "Allow"
#       Principal = {
#         AWS = "arn:aws:iam::241886877002:user/Sahil_demo_admin"
#       }
#       Action = [
#         "kms:Encrypt",
#         "kms:Decrypt",
#         "kms:ReEncrypt*",
#         "kms:GenerateDataKey*",
#         "kms:DescribeKey"
#       ]
#       Resource = "*"
#     }
#   ]
# })
#  }

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
          "kms:Create*",
          "kms:Describe*",
          "kms:Enable*",
          "kms:List*",
          "kms:Put*",
          "kms:Update*",
          "kms:Revoke*",
          "kms:Disable*",
          "kms:Get*"
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

// Alias to EBS KEY
resource "aws_kms_alias" "rds_encryption_key" {
  name          = "alias/RDS_KEY"
  target_key_id = aws_kms_key.rds_encryption_key.id
}





## Symmetric EBS Key for encryption & decryption.

data "aws_caller_identity" "current" {}

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

// Alias to EBS KEY
resource "aws_kms_alias" "ebs_key" {
  name          = "alias/EBS_KEY"
  target_key_id = aws_kms_key.ebs_key.id
}

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

output "rds_endpoint" {
  value = aws_db_instance.rds_instance.endpoint
}

###Assignment06#####

variable "domain_name" {
  type = string
}

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

output "load_balancer_dns_name" {
  value = aws_lb.load_balancer.dns_name
}

# output "public_ip" {
#   value = aws_instance.Terraform_Managed[0].public_ip
# }


data "aws_route53_zone" "main" {
  name = var.domain_name

}

# resource "aws_route53_record" "web" {
#   name    = var.domain_name
#   type    = "A"
#   zone_id = data.aws_route53_zone.main.zone_id

#   ttl = 30
#   records = [
#     aws_instance.Terraform_Managed[0].public_ip,
#   ]
# }

######Assignment06####
resource "aws_lb_listener" "lb_listener" {

  load_balancer_arn = aws_lb.load_balancer.arn
  port              = "443"
  protocol          = "HTTPS"
  certificate_arn   = data.aws_acm_certificate.aws_acm_certificate.arn
  //arn:aws:acm:us-east-2:241886877002:certificate/30aee16a-9a7f-4e01-9cac-cb66799ce79a
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.target_group.arn
  }

}


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

# Upscaling 

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


#Downscaling 

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

resource "aws_autoscaling_policy" "upautoscaling_policy" {
  name                   = "upautoscaling_policy"
  scaling_adjustment     = 1
  adjustment_type        = "PercentChangeInCapacity"
  cooldown               = 60
  autoscaling_group_name = aws_autoscaling_group.autoscaling.name
}


resource "aws_autoscaling_policy" "downautoscaling_policy" {
  name                   = "downautoscaling_policy"
  scaling_adjustment     = -1
  adjustment_type        = "PercentChangeInCapacity"
  cooldown               = 60
  autoscaling_group_name = aws_autoscaling_group.autoscaling.name
}


resource "aws_cloudwatch_log_group" "csye6225-spring2023" {
  name = "csye6225-spring2023"
}

data "aws_acm_certificate" "aws_acm_certificate" {
  domain   = var.domain_name
  statuses = ["ISSUED"]
}

# resource "aws_lb_listener_certificate" "aws_lb_listener_certificate" {
#   listener_arn    = "${aws_lb_listener.lb_listener.arn}"
#   certificate_arn = "${data.aws_acm_certificate.aws_acm_certificate.arn}"
# }

