provider "aws" {
  region  = var.region
  profile = "infra_test"
}

variable "protocol" {
  default = {
    tcp  = 6
    udp  = 17
    icmp = 1
  }
}

variable "vpc_name" {}
variable "vpc2_name" {}
variable "region" {}
variable "vpc_cidr" {}
variable "vpc2_cidr" {}


resource "aws_security_group" "allow_ssh" {
  name        = "terraform-testing-test_vpc"
  description = "Allow SSH inbound traffic"
  vpc_id      = module.test-vpc.vpc_id

  ingress {
    description = "Allow SSH"
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

  tags = {
    Name = "terraform-testing-test_vpc-SSH"
  }
}

module "test-vpc" {
  #source = "git::git@github.com:seunaw/terraform-aws-vpc.git"
  source = "../"

  name = var.vpc_name

  cidr = var.vpc_cidr

  azs = ["us-west-2a", "us-west-2b"]

  public_subnets = ["10.0.1.0/25", "10.0.1.128/25"]
  # private_subnets  = ["10.0.2.0/25", "10.0.2.128/25"]
  # outbound_subnets = ["10.0.3.0/25", "10.0.3.128/25"]
  # transit_subnets  = ["10.0.4.0/25", "10.0.4.128/25"]

  enable_nat_gateway     = true
  enable_transit_gateway = true

  tags = {
    Name = var.vpc_name
  }

  public_subnet_suffix   = "public"
  private_subnet_suffix  = "private"
  outbound_subnet_suffix = "outbound"
  transit_subnet_suffix  = "transit"

  # default_network_acl_tags    = module.core_infra_defaults.default_network_acl_tags
  public_inbound_acl_rules = [
    {
      rule_number = 103
      rule_action = "allow"
      from_port   = 80
      to_port     = 80
      protocol    = var.protocol["tcp"]
      cidr_block  = "0.0.0.0/0"
    },
    {
      rule_number = 104
      rule_action = "allow"
      from_port   = 22
      to_port     = 22
      protocol    = var.protocol["tcp"]
      cidr_block  = "0.0.0.0/0"
    }

  ]
  public_outbound_acl_rules = [
    {
      rule_number = 100
      rule_action = "allow"
      from_port   = 0
      to_port     = 0
      protocol    = -1
      cidr_block  = "0.0.0.0/0"
    }
  ]
}

module "test-vpc2" {
  #source = "git::git@github.com:seunaw/terraform-aws-vpc.git"
  source = "../"
  name   = var.vpc2_name
  cidr   = var.vpc2_cidr

  azs = ["us-west-2a", "us-west-2b"]

  subnet_with_names = true
  public_subnets_with_names = [
    {
      name = "test_app1"
      type = "public"
      cidr = "11.0.1.0/25"
    },
    {
      name = "test_app1"
      type = "public"
      cidr = "11.0.1.128/25"
    }
  ]
  private_subnets_with_names = [
    {
      name = "test_app1"
      type = "private"
      cidr = "11.0.2.0/25"
    },
    {
      name = "test_app1"
      type = "private"
      cidr = "11.0.2.128/25"
    }
  ]
  outbound_subnets_with_names = [
    {
      name = "test_app1"
      type = "outbound"
      cidr = "11.0.3.0/25"
    },
    {
      name = "test_app1"
      type = "outbound"
      cidr = "11.0.3.128/25"
    }
  ]
  transit_subnets_with_names = [
    {
      name = "test_app1"
      type = "transit"
      cidr = "11.0.4.0/25"
    },
    {
      name = "test_app1"
      type = "transit"
      cidr = "11.0.4.128/25"
    }
  ]

  tags = {
    Name = "terraform-testing-test_vpc2"
  }

  public_subnet_suffix   = "public"
  private_subnet_suffix  = "private"
  outbound_subnet_suffix = "outbound"
  transit_subnet_suffix  = "transit"

  # default_network_acl_tags    = module.core_infra_defaults.default_network_acl_tags
  public_inbound_acl_rules = [
    {
      rule_number = 103
      rule_action = "allow"
      from_port   = 80
      to_port     = 80
      protocol    = var.protocol["tcp"]
      cidr_block  = "0.0.0.0/0"
    }
  ]
  public_outbound_acl_rules = []

  transit_gateway_id = module.test-vpc.transit_gateway_id
}
