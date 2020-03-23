provider "aws" {
  region  = "us-west-2"
  profile = "infra_test"
}

variable "protocol" {
  default = {
    tcp  = 6
    udp  = 17
    icmp = 1
  }
}

module "test-vpc" {
  source = "git::git@github.com:seunaw/terraform-aws-vpc.git"

  name = "terraform-testing-test_vpc"
  cidr = "10.0.0.0/16"

  azs = ["us-west-2a", "us-west-2b"]

  public_subnets   = ["10.0.1.0/25", "10.0.1.128/25"]
  private_subnets  = ["10.0.2.0/25", "10.0.2.128/25"]
  outbound_subnets = ["10.0.3.0/25", "10.0.3.128/25"]
  transit_subnets  = ["10.0.4.0/25", "10.0.4.128/25"]

  enable_nat_gateway     = true
  enable_transit_gateway = true

  tags = {
    Name = "terraform-testing-test_vpc"
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
}

module "test-vpc2" {
  source = "git::git@github.com:seunaw/terraform-aws-vpc.git"

  name = "terraform-testing-test_vpc2"
  cidr = "11.0.0.0/16"

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
}