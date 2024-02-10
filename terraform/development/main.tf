
terraform {
  backend "s3" {
  }
}

data "aws_availability_zones" "available" {}

# data "aws_secretsmanager_secret_version" "db_password" {
#   secret_id = module.db_default.db_instance_master_user_secret_arn
# }

locals {
  name   = "dow-cs2-dev-test"
  region = "eu-west-1"



  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  container_name = "client"
  container_port = 80

  api_container_image_uri       = "${var.container_registry}/${var.namespace}/${var.api_image_name}:${var.api_image_tag}"
  dashboard_container_image_uri = "${var.container_registry}/${var.namespace}/${var.dashboard_image_name}:${var.dashboard_image_tag}"
  client_container_image_uri    = "${var.container_registry}/${var.namespace}/${var.client_image_name}:${var.client_image_tag}"

  #   db_credentials = jsondecode(data.aws_secretsmanager_secret_version.db_password.secret_string)
  #   db_password    = local.db_credentials.password

  tags = {
    Name = local.name
  }

  user_data = <<-EOT
        #!/bin/bash

        cat <<'EOF' >> /etc/ecs/ecs.config
        ECS_CLUSTER="${local.name}"
        ECS_LOGLEVEL=debug
        ECS_CONTAINER_INSTANCE_TAGS=${jsonencode(local.tags)}
        ECS_ENABLE_TASK_IAM_ROLE=true
        EOF
      EOT

  postgres_user     = "postgres"
  postgres_password = "helloworld"
  postgres_db_name  = "postgres"

}

################################################################################
# Cluster
################################################################################

module "ecs_cluster" {
  source = "terraform-aws-modules/ecs/aws"

  cluster_name = local.name

  # Capacity provider - autoscaling groups
  default_capacity_provider_use_fargate = false

  autoscaling_capacity_providers = {
    # On-demand instances
    "${local.name}" = {
      auto_scaling_group_arn         = module.autoscaling.autoscaling_group_arn
      managed_termination_protection = "ENABLED"

      managed_scaling = {
        maximum_scaling_step_size = 5
        minimum_scaling_step_size = 1
        status                    = "ENABLED"
        target_capacity           = 60
      }

      default_capacity_provider_strategy = {
        weight = 100
        base   = 1
      }
    }
  }

  tags = local.tags
}

################################################################################
# Service
################################################################################

module "api" {
  source = "terraform-aws-modules/ecs/aws//modules/service"

  # Service
  name        = "${local.name}_api"
  cluster_arn = module.ecs_cluster.cluster_arn

  cpu    = 1024
  memory = 1024

  # Task Definition
  requires_compatibilities = ["EC2"]
  capacity_provider_strategy = { # On-demand instances
    ex_1 = {
      capacity_provider = module.ecs_cluster.autoscaling_capacity_providers["${local.name}"].name
      weight            = 1
      base              = 1
    }
  }


  volume = {
    name      = "db_seed_data"
    host_path = "../../database/seed.sql"
  }

  # Container definition(s)
  container_definitions = {
    ("${local.name}_api") = {
      cpu    = 256
      memory = 256
      image  = local.api_container_image_uri
      environment = [
        {
          name  = "DB_TYPE"
          value = "postgres"
        },
        {
          # TODO: use aws secret fields
          name  = "DB_URL"
          value = "postgres://${local.postgres_user}:${local.postgres_password}@${module.nlb.dns_name}:5432/${local.postgres_db_name}"
        },
        {
          name  = "API_URL"
          value = "${module.nlb.dns_name}:3000"
        },
        {
          name  = "DASHBOARD_URL"
          value = "${module.nlb.dns_name}:3001"
        },
        {
          name  = "ETHEREUM_NETWORK"
          value = "localhost"
        },
        {
          name  = "IRON_SESSION_PASSWORD"
          value = "JJ1EnoEPyesNnpdcDVD4ujVG2XKXJLQx"
        },
        {
          name  = "BACKEND_PRIVATE_KEY"
          value = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
        },
        {
          name  = "GITHUB_CLIENT_ID"
          value = "a83a8b014ef38270fb22"
        },
        {
          name  = "TWITTER_CLIENT_ID"
          value = "NV82Mm85NWlSZ1llZkpLMl9vN3A6MTpjaQ"
        }
      ]

      port_mappings = [
        {
          name          = "api"
          containerPort = 3000
          protocol      = "tcp"
        }
      ]

      # Example image used requires access to write to root filesystem
      readonly_root_filesystem = false
    },

    ("${local.name}_db") = {
      cpu    = 256
      memory = 256
      image  = "postgres:16-alpine"
      environment = [
        {
          name  = "POSTGRES_USER"
          value = local.postgres_user
        },
        {
          name  = "POSTGRES_PASSWORD"
          value = local.postgres_password
        },
        {
          name  = "POSTGRES_DB"
          value = local.postgres_db_name
        }
      ]

      mountPoints = [
        {
          sourceVolume  = "db_seed_data"
          containerPath = "/docker-entrypoint-initdb.d/seed.sql"
        }
      ]

      port_mappings = [
        {
          name          = "db"
          containerPort = 5432
          protocol      = "tcp"
        }
      ]

      readonly_root_filesystem = false
    }


  }

  load_balancer = {
    service = {
      target_group_arn = module.nlb.target_groups["api"].arn
      container_name   = "${local.name}_api"
      container_port   = 3000
    },
    db = {
      target_group_arn = module.nlb.target_groups["db"].arn
      container_name   = "${local.name}_db"
      container_port   = 5432
    }
  }

  subnet_ids = module.vpc.private_subnets
  security_group_rules = {
    alb_http_ingress = {
      type                     = "ingress"
      from_port                = 3000
      to_port                  = 3000
      protocol                 = "tcp"
      description              = "Service port"
      source_security_group_id = module.nlb.security_group_id
    },
    alb_postgres_ingress = {
      type                     = "ingress"
      from_port                = 5432
      to_port                  = 5432
      protocol                 = "tcp"
      description              = "Service port"
      source_security_group_id = module.nlb.security_group_id
    },
    all_egress = {
      type        = "egress"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      description = "Allow all egress traffic"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  tags = local.tags
}

module "client" {
  source = "terraform-aws-modules/ecs/aws//modules/service"

  # Service
  name        = "${local.name}_client"
  cluster_arn = module.ecs_cluster.cluster_arn

  cpu    = 512
  memory = 512

  # Task Definition
  requires_compatibilities = ["EC2"]
  capacity_provider_strategy = {
    # On-demand instances
    ex_1 = {
      capacity_provider = module.ecs_cluster.autoscaling_capacity_providers["${local.name}"].name
      weight            = 1
      base              = 1
    }
  }

  # Container definition(s)
  container_definitions = {
    ("${local.name}_client") = {
      cpu    = 256
      memory = 256
      image  = local.client_container_image_uri
      port_mappings = [
        {
          name          = "${local.name}_client"
          containerPort = local.container_port
          protocol      = "tcp"
        }
      ]

      # Example image used requires access to write to root filesystem
      readonly_root_filesystem = false
    }
  }

  load_balancer = {
    service = {
      target_group_arn = module.nlb.target_groups["dow-cs2"].arn
      container_name   = "${local.name}_client"
      container_port   = local.container_port
    }
  }

  subnet_ids = module.vpc.private_subnets
  security_group_rules = {
    alb_http_ingress = {
      type                     = "ingress"
      from_port                = local.container_port
      to_port                  = local.container_port
      protocol                 = "tcp"
      description              = "Service port"
      source_security_group_id = module.nlb.security_group_id
    }
  }

  tags = local.tags
}

module "dashboard" {
  source = "terraform-aws-modules/ecs/aws//modules/service"

  # Service
  name        = "${local.name}_dashboard"
  cluster_arn = module.ecs_cluster.cluster_arn

  cpu    = 512
  memory = 512

  # Task Definition
  requires_compatibilities = ["EC2"]
  capacity_provider_strategy = {
    # On-demand instances
    ex_1 = {
      capacity_provider = module.ecs_cluster.autoscaling_capacity_providers["${local.name}"].name
      weight            = 1
      base              = 1
    }
  }

  # Container definition(s)
  container_definitions = {
    ("${local.name}_dashboard") = {
      cpu    = 256
      memory = 256
      image  = local.dashboard_container_image_uri
      port_mappings = [
        {
          name          = "${local.name}_dashboard"
          containerPort = local.container_port
          protocol      = "tcp"
        }
      ]

      # Example image used requires access to write to root filesystem
      readonly_root_filesystem = false
    }
  }

  load_balancer = {
    service = {
      target_group_arn = module.nlb.target_groups["dashboard"].arn
      container_name   = "${local.name}_dashboard"
      container_port   = local.container_port
    }
  }

  subnet_ids = module.vpc.private_subnets
  security_group_rules = {
    alb_http_ingress = {
      type                     = "ingress"
      from_port                = 80
      to_port                  = 80
      protocol                 = "tcp"
      description              = "Service port"
      source_security_group_id = module.nlb.security_group_id
    }
  }

  tags = local.tags
}


################################################################################
# Supporting Resources
################################################################################

# https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-optimized_AMI.html#ecs-optimized-ami-linux
data "aws_ssm_parameter" "ecs_optimized_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/recommended"
}

module "nlb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 9.0"

  name = local.name

  load_balancer_type = "network"

  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.public_subnets

  enable_deletion_protection = false

  # Security Group
  security_group_ingress_rules = {
    api = {
      from_port   = 3000
      to_port     = 3000
      ip_protocol = "tcp"
      cidr_ipv4   = "0.0.0.0/0"
    }

    all_http = {
      from_port   = 80
      to_port     = 80
      ip_protocol = "tcp"
      cidr_ipv4   = "0.0.0.0/0"
    }

    dashboard = {
      from_port   = 3001
      to_port     = 3001
      ip_protocol = "tcp"
      cidr_ipv4   = "0.0.0.0/0"
    }

    db = {
      from_port   = 5432
      to_port     = 5432
      ip_protocol = "tcp"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }
  security_group_egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = module.vpc.vpc_cidr_block
    }
  }

  listeners = {

    ex_api = {
      port     = 3000
      protocol = "TCP"

      forward = {
        target_group_key = "api"
      }
    }

    ex_client = {
      port     = 80
      protocol = "TCP"

      forward = {
        target_group_key = "dow-cs2"
      }
    }

    ex_dashboard = {
      port     = 3001
      protocol = "TCP"

      forward = {
        target_group_key = "dashboard"
      }
    }

    ex_db = {
      port     = 5432
      protocol = "TCP"

      forward = {
        target_group_key = "db"
      }
    }
  }



  target_groups = {

    api = {
      protocol                          = "TCP"
      port                              = 3000
      target_type                       = "ip"
      deregistration_delay              = 5
      load_balancing_cross_zone_enabled = true

      health_check = {
        enabled             = true
        healthy_threshold   = 5
        interval            = 30
        matcher             = "200"
        path                = "/"
        port                = "traffic-port"
        protocol            = "HTTP"
        timeout             = 5
        unhealthy_threshold = 2
      }

      # Theres nothing to attach here in this definition. Instead,
      # ECS will attach the IPs of the tasks to this target group
      create_attachment = false
    }

    dow-cs2 = {
      protocol                          = "TCP"
      port                              = 80
      target_type                       = "ip"
      deregistration_delay              = 5
      load_balancing_cross_zone_enabled = true

      health_check = {
        enabled             = true
        healthy_threshold   = 5
        interval            = 30
        matcher             = "200"
        path                = "/"
        port                = "traffic-port"
        protocol            = "HTTP"
        timeout             = 5
        unhealthy_threshold = 2
      }

      # Theres nothing to attach here in this definition. Instead,
      # ECS will attach the IPs of the tasks to this target group
      create_attachment = false
    }

    dashboard = {
      protocol                          = "TCP"
      port                              = local.container_port
      target_type                       = "ip"
      deregistration_delay              = 5
      load_balancing_cross_zone_enabled = true

      health_check = {
        enabled             = true
        healthy_threshold   = 5
        interval            = 30
        matcher             = "200"
        path                = "/"
        port                = "traffic-port"
        protocol            = "HTTP"
        timeout             = 5
        unhealthy_threshold = 2
      }

      # Theres nothing to attach here in this definition. Instead,
      # ECS will attach the IPs of the tasks to this target group
      create_attachment = false
    }

    db = {
      #   protocol                  = "TCP"
      #   port                      = 5432
      protocol : "TCP"
      port : 5432
      target_type                       = "ip"
      deregistration_delay              = 300
      load_balancing_cross_zone_enabled = true

      health_check = {
        enabled             = true
        healthy_threshold   = 5
        interval            = 30
        timeout             = 5
        unhealthy_threshold = 2
      }

      # Theres nothing to attach here in this definition. Instead,
      # ECS will attach the IPs of the tasks to this target group
      create_attachment = false
    }
  }

  tags = local.tags
}

module "autoscaling" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "~> 6.5"


  # On-demand instances

  instance_type              = "t3.medium"
  use_mixed_instances_policy = false

  block_device_mappings = [
    {
      # Root volume
      device_name = "/dev/xvda"
      no_device   = 0
      ebs = {
        delete_on_termination = true
        encrypted             = true
        volume_size           = 50
        volume_type           = "gp2"
      }
    }
  ]


  user_data = base64encode(local.user_data)


  name = local.name

  image_id = jsondecode(data.aws_ssm_parameter.ecs_optimized_ami.value)["image_id"]


  security_groups = [module.autoscaling_sg.security_group_id]

  ignore_desired_capacity_changes = true

  iam_instance_profile_name   = "ecsInstanceRole"
  create_iam_instance_profile = false
  # iam_role_name               = local.name

  #iam_role_description        = "ECS role for "${local.name}""
  #iam_role_policies = {
  #  AmazonEC2ContainerServiceforEC2Role = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
  #  AmazonSSMManagedInstanceCore        = "arn:aws:iam::aws:policy/#AmazonSSMManagedInstanceCore"
  #}

  vpc_zone_identifier = module.vpc.private_subnets
  health_check_type   = "EC2"
  min_size            = 1
  max_size            = 3
  desired_capacity    = 1

  # https://github.com/hashicorp/terraform-provider-aws/issues/12582
  autoscaling_group_tags = {
    AmazonECSManaged = true
  }

  # Required for  managed_termination_protection = "ENABLED"
  protect_from_scale_in = true

  tags = local.tags
}

module "autoscaling_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = local.name
  description = "Autoscaling group security group"
  vpc_id      = module.vpc.vpc_id

  computed_ingress_with_source_security_group_id = [
    {
      rule                     = "http-80-tcp"
      source_security_group_id = module.nlb.security_group_id
    }
  ]
  number_of_computed_ingress_with_source_security_group_id = 1

  egress_rules = ["all-all"]

  tags = local.tags
}
