locals {
  max_subnet_length = max(
    length(var.outbound_subnets),
    length(var.outbound_subnets_with_names),
    length(var.elasticache_subnets),
    length(var.database_subnets),
    length(var.redshift_subnets),
  )
  nat_gateway_count = var.single_nat_gateway ? 1 : var.one_nat_gateway_per_az ? length(var.azs) : local.max_subnet_length

  # merged_nat_gateway_acl = concat(
  #   var.public_inbound_acl_rules,
  #   [{
  #     rule_number = 100
  #     rule_action = "allow"
  #     from_port   = 0
  #     to_port     = 0
  #     protocol    = -1
  #     cidr_block  = "${aws_nat_gateway.this[0].public_ip}/32"
  #   }]
  # )



  # public_inbound_acl_rules = var.enable_nat_gateway ? local.merged_nat_gateway_acl : var.public_inbound_acl_rules

  # Use `local.vpc_id` to give a hint to Terraform that subnets should be deleted before secondary CIDR blocks can be free!
  vpc_id = element(
    concat(
      aws_vpc_ipv4_cidr_block_association.this.*.vpc_id,
      aws_vpc.this.*.id,
      [""],
    ),
    0,
  )

  vpce_tags = merge(
    var.tags,
    var.vpc_endpoint_tags,
  )
}

#####*******************************************#####
# Core
#####*******************************************#####

######
# VPC
######
resource "aws_vpc" "this" {
  count = var.create_vpc ? 1 : 0

  cidr_block                       = var.cidr
  instance_tenancy                 = var.instance_tenancy
  enable_dns_hostnames             = var.enable_dns_hostnames
  enable_dns_support               = var.enable_dns_support
  enable_classiclink               = var.enable_classiclink
  enable_classiclink_dns_support   = var.enable_classiclink_dns_support
  assign_generated_ipv6_cidr_block = var.enable_ipv6

  tags = merge(
    {
      "Name" = format("%s", var.name)
    },
    var.tags,
    var.vpc_tags,
  )
}

resource "aws_vpc_ipv4_cidr_block_association" "this" {
  count = var.create_vpc && length(var.secondary_cidr_blocks) > 0 ? length(var.secondary_cidr_blocks) : 0

  vpc_id = aws_vpc.this[0].id

  cidr_block = element(var.secondary_cidr_blocks, count.index)
}

###################
# Internet Gateway
###################
resource "aws_internet_gateway" "this" {
  count = var.create_vpc && (length(var.public_subnets) > 0 || length(var.public_subnets_with_names) > 0 || length(var.outbound_subnets) > 0 || length(var.outbound_subnets_with_names) > 0) ? 1 : 0

  vpc_id = local.vpc_id

  tags = merge(
    {
      "Name" = format("%s", var.name)
    },
    var.tags,
    var.igw_tags,
  )
}

resource "aws_egress_only_internet_gateway" "this" {
  count = var.create_vpc && var.enable_ipv6 && local.max_subnet_length > 0 ? 1 : 0

  vpc_id = local.vpc_id
}

##############
# NAT Gateway
##############
# Workaround for interpolation not being able to "short-circuit" the evaluation of the conditional branch that doesn't end up being used
# Source: https://github.com/hashicorp/terraform/issues/11566#issuecomment-289417805
#
# The logical expression would be
#
#    nat_gateway_ips = var.reuse_nat_ips ? var.external_nat_ip_ids : aws_eip.nat.*.id
#
# but then when count of aws_eip.nat.*.id is zero, this would throw a resource not found error on aws_eip.nat.*.id.
locals {
  nat_gateway_ips = split(
    ",",
    var.reuse_nat_ips ? join(",", var.external_nat_ip_ids) : join(",", aws_eip.nat.*.id),
  )
}

resource "aws_eip" "nat" {
  count = var.create_vpc && var.enable_nat_gateway && false == var.reuse_nat_ips ? local.nat_gateway_count : 0

  vpc = true

  tags = merge(
    {
      "Name" = format(
        "%s-%s",
        var.name,
        element(var.azs, var.single_nat_gateway ? 0 : count.index),
      )
    },
    var.tags,
    var.nat_eip_tags,
  )
}

resource "aws_nat_gateway" "this" {
  count = var.create_vpc && var.enable_nat_gateway && (length(var.outbound_subnets) > 0 || length(var.outbound_subnets_with_names) > 0) ? local.nat_gateway_count : 0

  allocation_id = element(
    local.nat_gateway_ips,
    var.single_nat_gateway ? 0 : count.index,
  )

  # check both subnet and subnet_with_names
  subnet_id = ! var.subnet_with_names ? element(aws_subnet.public.*.id, var.single_nat_gateway ? 0 : count.index) : element(aws_subnet.public_with_names.*.id, var.single_nat_gateway ? 0 : count.index)

  tags = merge(
    {
      "Name" = format(
        "%s-%s",
        var.name,
        element(var.azs, var.single_nat_gateway ? 0 : count.index),
      )
    },
    var.tags,
    var.nat_gateway_tags,
  )

  depends_on = [aws_internet_gateway.this]
}

##############
# VPN Gateway
##############
resource "aws_vpn_gateway" "this" {
  count = var.create_vpc && var.enable_vpn_gateway ? 1 : 0

  vpc_id          = local.vpc_id
  amazon_side_asn = var.amazon_side_asn

  tags = merge(
    {
      "Name" = format("%s", var.name)
    },
    var.tags,
    var.vpn_gateway_tags,
  )
}

resource "aws_vpn_gateway_attachment" "this" {
  count = var.vpn_gateway_id != "" ? 1 : 0

  vpc_id         = local.vpc_id
  vpn_gateway_id = var.vpn_gateway_id
}

resource "aws_vpn_gateway_route_propagation" "public" {
  count = var.create_vpc && var.propagate_public_route_tables_vgw && (var.enable_vpn_gateway || var.vpn_gateway_id != "") ? 1 : 0

  route_table_id = element(aws_route_table.public.*.id, count.index)
  vpn_gateway_id = element(
    concat(
      aws_vpn_gateway.this.*.id,
      aws_vpn_gateway_attachment.this.*.vpn_gateway_id,
    ),
    count.index,
  )
}

resource "aws_vpn_gateway_route_propagation" "outbound" {
  count = var.create_vpc && var.propagate_outbound_route_tables_vgw && (var.enable_vpn_gateway || var.vpn_gateway_id != "") ? length(var.outbound_subnets) : 0

  route_table_id = element(aws_route_table.outbound.*.id, count.index)
  vpn_gateway_id = element(
    concat(
      aws_vpn_gateway.this.*.id,
      aws_vpn_gateway_attachment.this.*.vpn_gateway_id,
    ),
    count.index,
  )
}

###########
# Transit gateway
###########
resource "aws_ec2_transit_gateway" "this" {
  count = var.create_vpc && var.enable_transit_gateway ? 1 : 0

  tags = merge(
    {
      "Name" = format("%s", var.name)
    },
    var.tags,
    var.transit_subnet_tags,
  )
}

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  count = var.create_vpc && (length(var.transit_subnets_with_names) > 0 || length(var.transit_subnets) > 0) ? 1 : 0

  subnet_ids = length(var.transit_subnets) > 0 ? aws_subnet.transit.*.id : aws_subnet.transit_with_names.*.id

  transit_gateway_id = var.enable_transit_gateway ? aws_ec2_transit_gateway.this[0].id : var.transit_gateway_id
  vpc_id             = local.vpc_id

  tags = merge(
    {
      "Name" = format("%s", var.name)
    },
    var.tags,
    var.transit_subnet_tags,
  )

  depends_on = [aws_ec2_transit_gateway.this]
}




######
# DHCP
######
resource "aws_vpc_dhcp_options" "this" {
  count = var.create_vpc && var.enable_dhcp_options ? 1 : 0

  domain_name          = var.dhcp_options_domain_name
  domain_name_servers  = var.dhcp_options_domain_name_servers
  ntp_servers          = var.dhcp_options_ntp_servers
  netbios_name_servers = var.dhcp_options_netbios_name_servers
  netbios_node_type    = var.dhcp_options_netbios_node_type

  tags = merge(
    {
      "Name" = format("%s", var.name)
    },
    var.tags,
    var.dhcp_options_tags,
  )
}

resource "aws_vpc_dhcp_options_association" "this" {
  count = var.create_vpc && var.enable_dhcp_options ? 1 : 0

  vpc_id          = local.vpc_id
  dhcp_options_id = aws_vpc_dhcp_options.this[0].id
}


#####*******************************************#####
# Subnets
#####*******************************************#####

################
# Public subnet
################
resource "aws_subnet" "public" {
  # @TODO - this might not work
  count = var.create_vpc && ! var.subnet_with_names && length(var.public_subnets) > 0 && (! var.one_nat_gateway_per_az || length(var.public_subnets) >= length(var.azs)) ? length(var.public_subnets) : 0

  vpc_id     = local.vpc_id
  cidr_block = element(concat(var.public_subnets, [""]), count.index)

  availability_zone               = element(var.azs, count.index)
  map_public_ip_on_launch         = var.map_public_ip_on_launch
  assign_ipv6_address_on_creation = var.public_subnet_assign_ipv6_address_on_creation == null ? var.assign_ipv6_address_on_creation : var.public_subnet_assign_ipv6_address_on_creation

  ipv6_cidr_block = var.enable_ipv6 && length(var.public_subnet_ipv6_prefixes) > 0 ? cidrsubnet(aws_vpc.this[0].ipv6_cidr_block, 8, var.public_subnet_ipv6_prefixes[count.index]) : null

  tags = merge(
    {
      "Name" = format(
        "%s-${var.public_subnet_suffix}-%s",
        var.name,
        element(var.azs, count.index),
      )
    },
    var.tags,
    var.public_subnet_tags,
  )
}

resource "aws_subnet" "public_with_names" {
  #count = var.create_vpc && var.subnet_with_names && length(var.public_subnets_with_names) > 0 && (!var.one_nat_gateway_per_az || length(var.public_subnets_with_names) >= length(var.azs)) ? length(var.public_subnets_with_names) : 0
  count = var.create_vpc && var.subnet_with_names && length(var.public_subnets_with_names) > 0 ? length(var.public_subnets_with_names) : 0

  vpc_id     = local.vpc_id
  cidr_block = element(var.public_subnets_with_names, count.index)["cidr"]

  availability_zone               = element(var.azs, count.index)
  map_public_ip_on_launch         = var.map_public_ip_on_launch
  assign_ipv6_address_on_creation = var.public_subnet_assign_ipv6_address_on_creation == null ? var.assign_ipv6_address_on_creation : var.outbound_subnet_assign_ipv6_address_on_creation

  ipv6_cidr_block = var.enable_ipv6 && length(var.outbound_subnet_ipv6_prefixes) > 0 ? cidrsubnet(aws_vpc.this[0].ipv6_cidr_block, 8, var.outbound_subnet_ipv6_prefixes[count.index]) : null

  tags = merge(
    {
      # "Name" = format(
      #   "%s-${var.private_subnet_suffix}-%s",
      #   var.name,
      #   element(var.azs, count.index),
      # )
      component = element(var.public_subnets_with_names, count.index)["name"]
      type      = element(var.public_subnets_with_names, count.index)["type"]
    },
    var.tags,
    var.public_subnet_tags,
    length(var.public_subnet_tags) > 0 ? {
      # Replacing region with AZ name
      Name = format(
        "%s-%s-%s",
        replace(var.public_subnet_tags["Name"], local.region, element(var.azs, count.index)),
        element(var.public_subnets_with_names, count.index)["type"],
        element(var.public_subnets_with_names, count.index)["name"],
      ),
    } : {},
  )
}

#################
# Outbound Subnet
#################
resource "aws_subnet" "outbound" {
  count = var.create_vpc && ! var.subnet_with_names && length(var.outbound_subnets) > 0 ? length(var.outbound_subnets) : 0

  vpc_id                          = local.vpc_id
  cidr_block                      = var.outbound_subnets[count.index]
  availability_zone               = element(var.azs, count.index)
  assign_ipv6_address_on_creation = var.outbound_subnet_assign_ipv6_address_on_creation == null ? var.assign_ipv6_address_on_creation : var.outbound_subnet_assign_ipv6_address_on_creation

  ipv6_cidr_block = var.enable_ipv6 && length(var.outbound_subnet_ipv6_prefixes) > 0 ? cidrsubnet(aws_vpc.this[0].ipv6_cidr_block, 8, var.outbound_subnet_ipv6_prefixes[count.index]) : null

  tags = merge(
    {
      "Name" = format(
        "%s-${var.outbound_subnet_suffix}-%s",
        var.name,
        element(var.azs, count.index),
      )
    },
    var.tags,
    var.outbound_subnet_tags,
  )
}

resource "aws_subnet" "outbound_with_names" {
  # count = var.create_vpc && var.subnet_with_names && length(var.public_subnets_with_names) > 0 && (!var.one_nat_gateway_per_az || length(var.public_subnets_with_names) >= length(var.azs)) ? length(var.public_subnets_with_names) : 0
  count = var.create_vpc && var.subnet_with_names && length(var.outbound_subnets_with_names) > 0 ? length(var.outbound_subnets_with_names) : 0

  vpc_id = local.vpc_id

  cidr_block                      = element(var.outbound_subnets_with_names, count.index)["cidr"]
  availability_zone               = element(var.azs, count.index)
  assign_ipv6_address_on_creation = var.outbound_subnet_assign_ipv6_address_on_creation == null ? var.assign_ipv6_address_on_creation : var.outbound_subnet_assign_ipv6_address_on_creation

  ipv6_cidr_block = var.enable_ipv6 && length(var.outbound_subnet_ipv6_prefixes) > 0 ? cidrsubnet(aws_vpc.this[0].ipv6_cidr_block, 8, var.outbound_subnet_ipv6_prefixes[count.index]) : null

  tags = merge(
    {
      # "Name" = format(
      #   "%s-${var.private_subnet_suffix}-%s",
      #   var.name,
      #   element(var.azs, count.index),
      # )
      component = element(var.outbound_subnets_with_names, count.index)["name"]
      type      = element(var.outbound_subnets_with_names, count.index)["type"]
    },
    var.tags,
    var.outbound_subnet_tags,
    # @TODO - Add legnth to all subnets tags above and make sure name is modified
    length(var.outbound_subnet_tags) > 0 ? {
      # Replacing region with AZ name
      Name = format(
        "%s-%s-%s",
        replace(var.outbound_subnet_tags["Name"], local.region, element(var.azs, count.index)),
        element(var.outbound_subnets_with_names, count.index)["type"],
        element(var.outbound_subnets_with_names, count.index)["name"],
      ),
    } : {},
  )
}

#################
# Private Subnets
#################
resource "aws_subnet" "private" {
  count = var.create_vpc && ! var.subnet_with_names && length(var.private_subnets) > 0 ? length(var.private_subnets) : 0

  vpc_id     = local.vpc_id
  cidr_block = var.private_subnets[count.index]

  availability_zone               = element(var.azs, count.index)
  assign_ipv6_address_on_creation = var.private_subnet_assign_ipv6_address_on_creation == null ? var.assign_ipv6_address_on_creation : var.private_subnet_assign_ipv6_address_on_creation

  ipv6_cidr_block = var.enable_ipv6 && length(var.private_subnet_ipv6_prefixes) > 0 ? cidrsubnet(aws_vpc.this[0].ipv6_cidr_block, 8, var.private_subnet_ipv6_prefixes[count.index]) : null

  tags = merge(
    {
      "Name" = format(
        "%s-${var.private_subnet_suffix}-%s",
        var.name,
        element(var.azs, count.index),
      )
    },
    var.tags,
    var.private_subnet_tags,
  )
}

locals {
  # get region name from current az
  region = substr(element(var.azs, 0), 0, length(element(var.azs, 0)) - 1)

}

resource "aws_subnet" "private_with_names" {
  count = var.create_vpc && var.subnet_with_names && length(var.private_subnets_with_names) > 0 ? length(var.private_subnets_with_names) : 0

  vpc_id = local.vpc_id

  cidr_block                      = element(concat(var.private_subnets_with_names, [""]), count.index)["cidr"]
  availability_zone               = element(var.azs, count.index)
  assign_ipv6_address_on_creation = var.private_subnet_assign_ipv6_address_on_creation == null ? var.assign_ipv6_address_on_creation : var.private_subnet_assign_ipv6_address_on_creation

  ipv6_cidr_block = var.enable_ipv6 && length(var.private_subnet_ipv6_prefixes) > 0 ? cidrsubnet(aws_vpc.this[0].ipv6_cidr_block, 8, var.private_subnet_ipv6_prefixes[count.index]) : null

  tags = merge(
    {
      # "Name" = format(
      #   "%s-${var.private_subnet_suffix}-%s",
      #   var.name,
      #   element(var.azs, count.index),
      # )
      component = element(concat(var.private_subnets_with_names, [""]), count.index)["name"]
      type      = element(concat(var.private_subnets_with_names, [""]), count.index)["type"]
    },
    var.tags,
    var.private_subnet_tags,
    length(var.transit_subnet_tags) > 0 ? {
      # Replacing region with AZ name
      Name = format(
        "%s-%s-%s",
        replace(var.private_subnet_tags["Name"], local.region, element(var.azs, count.index)),
        element(concat(var.private_subnets_with_names, [""]), count.index)["type"],
        element(concat(var.private_subnets_with_names, [""]), count.index)["name"],
      ),
    } : {},
  )
}

#################
# Transit subnets
#################
resource "aws_subnet" "transit" {

  count = var.create_vpc && ! var.subnet_with_names && length(var.transit_subnets) > 0 ? length(var.transit_subnets) : 0

  vpc_id = local.vpc_id

  cidr_block        = element(var.transit_subnets, count.index)
  availability_zone = element(var.azs, count.index)

  # @TODO - create ipv6 variable, using private for now
  assign_ipv6_address_on_creation = var.private_subnet_assign_ipv6_address_on_creation == null ? var.assign_ipv6_address_on_creation : var.private_subnet_assign_ipv6_address_on_creation

  ipv6_cidr_block = var.enable_ipv6 && length(var.private_subnet_ipv6_prefixes) > 0 ? cidrsubnet(aws_vpc.this[0].ipv6_cidr_block, 8, var.private_subnet_ipv6_prefixes[count.index]) : null

  tags = merge(
    {
      "Name" = format(
        "%s-${var.transit_subnet_suffix}-%s",
        var.name,
        element(var.azs, count.index),
      )
    },
    var.tags,
    var.transit_subnet_tags,
  )
}

resource "aws_subnet" "transit_with_names" {
  count = var.create_vpc && var.subnet_with_names && length(var.transit_subnets_with_names) > 0 ? length(var.transit_subnets_with_names) : 0

  vpc_id = local.vpc_id

  cidr_block        = element(concat(var.transit_subnets_with_names, []), count.index)["cidr"]
  availability_zone = element(var.azs, count.index)

  # @TODO - create ipv6 variable
  assign_ipv6_address_on_creation = var.private_subnet_assign_ipv6_address_on_creation == null ? var.assign_ipv6_address_on_creation : var.private_subnet_assign_ipv6_address_on_creation

  ipv6_cidr_block = var.enable_ipv6 && length(var.private_subnet_ipv6_prefixes) > 0 ? cidrsubnet(aws_vpc.this[0].ipv6_cidr_block, 8, var.private_subnet_ipv6_prefixes[count.index]) : null

  tags = merge(
    {
      component = element(concat(var.transit_subnets_with_names, []), count.index)["name"]
      type      = element(concat(var.transit_subnets_with_names, []), count.index)["type"]
    },
    var.tags,
    var.transit_subnet_tags,
    length(var.transit_subnet_tags) > 0 ? {
      # Replacing region with AZ name
      Name = format(
        "%s-%s",
        replace(var.transit_subnet_tags["Name"], local.region, element(var.azs, count.index)),
        element(concat(var.transit_subnets_with_names, [""]), count.index)["type"],
      ),
      type = "transit"
    } : {},
  )
}


#####*******************************************#####
# Routes
#####*******************************************#####

###############
# Publiс routes
###############
resource "aws_route_table" "public" {
  count = var.create_vpc && (length(var.public_subnets) > 0 || length(var.public_subnets_with_names) > 0) ? 1 : 0

  vpc_id = local.vpc_id

  tags = merge(
    {
      "Name" = format("%s-${var.public_subnet_suffix}", var.name)
    },
    var.tags,
    {
      Name = var.single_nat_gateway ? "${var.tags["Name"]}-${var.public_subnet_suffix}" : format(
        "%s-${var.public_subnet_suffix}-%s",
        var.tags["Name"],
        element(var.azs, count.index),
      )
    },
    var.public_route_table_tags,
  )
}

resource "aws_route" "public_internet_gateway" {
  count = var.create_vpc && length(var.public_subnets) > 0 || length(var.public_subnets_with_names) > 0 ? 1 : 0

  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id

  timeouts {
    create = "5m"
  }
}

resource "aws_route" "public_internet_gateway_ipv6" {
  count = var.create_vpc && var.enable_ipv6 && length(var.public_subnets) > 0 || length(var.public_subnets_with_names) > 0 ? 1 : 0

  route_table_id              = aws_route_table.public[0].id
  destination_ipv6_cidr_block = "::/0"
  gateway_id                  = aws_internet_gateway.this[0].id
}

#################
# Outbound Routes
#################
resource "aws_route_table" "outbound" {
  count = var.create_vpc && (length(var.outbound_subnets) > 0 || length(var.outbound_subnets_with_names) > 0) ? local.nat_gateway_count : 0

  vpc_id = local.vpc_id

  tags = merge(
    {
      "Name" = var.single_nat_gateway ? "${var.name}-${var.outbound_subnet_suffix}" : format(
        "%s-${var.outbound_subnet_suffix}-%s",
        var.name,
        element(var.azs, count.index),
      )
    },
    var.tags,
    {
      "Name" = var.single_nat_gateway ? "${var.tags["Name"]}-${var.outbound_subnet_suffix}" : format(
        "%s-${var.outbound_subnet_suffix}-%s",
        var.tags["Name"],
        element(var.azs, count.index),
      )
    },
    # {
    #   Name = lookup(var.tags, "Name", "") != "" ? var.single_nat_gateway ? format("%s-%s", var.tags["Name"], var.outbound_subnet_suffix) : format("%s-%s-%s", var.tags["Name"], var.outbound_subnet_suffix,element(var.azs, count.index)) : ""
    # },
    # var.outbound_route_table_tags,
  )

  lifecycle {
    # When attaching VPN gateways it is common to define aws_vpn_gateway_route_propagation
    # resources that manipulate the attributes of the routing table (typically for the outbound subnets)
    ignore_changes = [propagating_vgws]
  }
}

resource "aws_route" "outbound_nat_gateway" {
  count = var.create_vpc && var.enable_nat_gateway && (length(var.outbound_subnets) > 0 || length(var.outbound_subnets_with_names) > 0) ? local.nat_gateway_count : 0

  route_table_id         = (length(aws_subnet.outbound.*.id) > 0 || length(aws_subnet.outbound_with_names.*.id) > 0) ? aws_route_table.outbound[count.index].id : count.index
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = (length(aws_subnet.outbound.*.id) > 0 || length(aws_subnet.outbound_with_names.*.id) > 0) ? element(aws_nat_gateway.this.*.id, count.index) : count.index

  timeouts {
    create = "5m"
  }

  depends_on = [aws_route_table.outbound]
}

# @TODO - You might not need this, outbound should always use NAT
resource "aws_route" "outbound_ipv6_egress" {
  count = var.enable_ipv6 ? length(var.outbound_subnets) : 0

  route_table_id              = element(aws_route_table.outbound.*.id, count.index)
  destination_ipv6_cidr_block = "::/0"
  egress_only_gateway_id      = element(aws_egress_only_internet_gateway.this.*.id, 0)
}

#################
# Private routes
#   Private subnets should only stay within VPC CIDR
#################
resource "aws_route_table" "private" {
  count = var.create_vpc && (length(var.private_subnets) > 0 || length(var.private_subnets_with_names) > 0) ? 1 : 0

  vpc_id = local.vpc_id

  tags = merge(
    {
      "Name" = "${var.name}-${var.private_subnet_suffix}"
    },
    var.tags,
    {
      "Name" = var.single_nat_gateway ? "${var.tags["Name"]}-${var.private_subnet_suffix}" : format(
        "%s-${var.private_subnet_suffix}-%s",
        var.tags["Name"],
        element(var.azs, count.index),
      )
    },
    var.private_route_table_tags,
  )
}

##########################
# Route table association
##########################

# @TODO - Merge with_names association with regular association

resource "aws_route_table_association" "public" {
  count = var.create_vpc && length(var.public_subnets) > 0 ? length(var.public_subnets) : 0

  subnet_id      = element(aws_subnet.public.*.id, count.index)
  route_table_id = aws_route_table.public[0].id

}

resource "aws_route_table_association" "outbound" {
  count = var.create_vpc && (length(var.outbound_subnets) > 0 || length(var.outbound_subnets_with_names) > 0) ? length(var.outbound_subnets) : 0

  subnet_id = var.subnet_with_names ? element(aws_subnet.outbound_with_names.*.id, count.index) : element(aws_subnet.outbound.*.id, count.index)
  route_table_id = element(
    aws_route_table.outbound.*.id,
    var.single_nat_gateway ? 0 : count.index,
  )
}

resource "aws_route_table_association" "private" {
  count = var.create_vpc && length(var.private_subnets) > 0 ? length(var.private_subnets) : 0

  subnet_id      = element(aws_subnet.private.*.id, count.index)
  route_table_id = element(aws_route_table.private.*.id, 0)
}

resource "aws_route_table_association" "public_with_names" {
  count = var.create_vpc && length(var.public_subnets_with_names) > 0 ? length(var.public_subnets_with_names) : 0

  subnet_id      = element(aws_subnet.public_with_names.*.id, count.index)
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table_association" "outbound_with_names" {
  count = var.create_vpc && length(var.outbound_subnets_with_names) > 0 ? length(var.outbound_subnets_with_names) : 0

  subnet_id      = element(aws_subnet.outbound_with_names.*.id, count.index)
  route_table_id = aws_route_table.outbound[0].id
}

resource "aws_route_table_association" "private_with_names" {
  count = var.create_vpc && length(var.private_subnets_with_names) > 0 ? length(var.private_subnets_with_names) : 0

  subnet_id      = element(aws_subnet.private_with_names.*.id, count.index)
  route_table_id = aws_route_table.private[0].id
}


#####*******************************************#####
# Network ACLs
#####*******************************************#####

#######################
# Default Network ACLs
#######################
resource "aws_default_network_acl" "this" {
  count = var.create_vpc && var.manage_default_network_acl ? 1 : 0

  default_network_acl_id = element(concat(aws_vpc.this.*.default_network_acl_id, [""]), 0)

  dynamic "ingress" {
    for_each = var.default_network_acl_ingress
    content {
      action          = ingress.value.action
      cidr_block      = lookup(ingress.value, "cidr_block", null)
      from_port       = ingress.value.from_port
      icmp_code       = lookup(ingress.value, "icmp_code", null)
      icmp_type       = lookup(ingress.value, "icmp_type", null)
      ipv6_cidr_block = lookup(ingress.value, "ipv6_cidr_block", null)
      protocol        = ingress.value.protocol
      rule_no         = ingress.value.rule_no
      to_port         = ingress.value.to_port
    }
  }
  dynamic "egress" {
    for_each = var.default_network_acl_egress
    content {
      action          = egress.value.action
      cidr_block      = lookup(egress.value, "cidr_block", null)
      from_port       = egress.value.from_port
      icmp_code       = lookup(egress.value, "icmp_code", null)
      icmp_type       = lookup(egress.value, "icmp_type", null)
      ipv6_cidr_block = lookup(egress.value, "ipv6_cidr_block", null)
      protocol        = egress.value.protocol
      rule_no         = egress.value.rule_no
      to_port         = egress.value.to_port
    }
  }

  tags = merge(
    {
      "Name" = format("%s", var.default_network_acl_name)
    },
    var.tags,
    var.default_network_acl_tags,
  )

  lifecycle {
    ignore_changes = [subnet_ids]
  }
}

########################
# Public Network ACLs
########################
resource "aws_network_acl" "public" {
  count = var.create_vpc && var.public_dedicated_network_acl && (length(var.public_subnets) > 0 || length(var.public_subnets_with_names) > 0) ? 1 : 0

  vpc_id     = element(concat(aws_vpc.this.*.id, [""]), 0)
  subnet_ids = ! var.subnet_with_names ? aws_subnet.public.*.id : aws_subnet.public_with_names.*.id

  tags = merge(
    {
      "Name" = format("%s-${var.public_subnet_suffix}", var.name)
    },
    var.tags,
    {
      Name        = format("%s-%s", var.tags["Name"], var.public_subnet_suffix)
      subnet_type = "public"
    },
    var.public_acl_tags,
  )
}


resource "aws_network_acl_rule" "public_inbound" {
  count = var.create_vpc && var.public_dedicated_network_acl && (length(var.public_subnets) > 0 || length(var.public_subnets_with_names) > 0) ? length(var.public_inbound_acl_rules) : 0

  network_acl_id = aws_network_acl.public[0].id

  egress      = false
  rule_number = var.public_inbound_acl_rules[count.index]["rule_number"]
  rule_action = var.public_inbound_acl_rules[count.index]["rule_action"]
  from_port   = lookup(var.public_inbound_acl_rules[count.index], "from_port", null)
  to_port     = lookup(var.public_inbound_acl_rules[count.index], "to_port", null)
  icmp_code   = lookup(var.public_inbound_acl_rules[count.index], "icmp_code", null)
  icmp_type   = lookup(var.public_inbound_acl_rules[count.index], "icmp_type", null)
  protocol    = var.public_inbound_acl_rules[count.index]["protocol"]
  cidr_block  = var.public_inbound_acl_rules[count.index]["cidr_block"]
}

resource "aws_network_acl_rule" "public_outbound" {
  count = var.create_vpc && var.public_dedicated_network_acl && (length(var.public_subnets) > 0 || length(var.public_subnets_with_names) > 0) ? length(var.public_outbound_acl_rules) : 0

  network_acl_id = aws_network_acl.public[0].id

  egress      = true
  rule_number = var.public_outbound_acl_rules[count.index]["rule_number"]
  rule_action = var.public_outbound_acl_rules[count.index]["rule_action"]
  from_port   = lookup(var.public_outbound_acl_rules[count.index], "from_port", null)
  to_port     = lookup(var.public_outbound_acl_rules[count.index], "to_port", null)
  icmp_code   = lookup(var.public_outbound_acl_rules[count.index], "icmp_code", null)
  icmp_type   = lookup(var.public_outbound_acl_rules[count.index], "icmp_type", null)
  protocol    = var.public_outbound_acl_rules[count.index]["protocol"]
  cidr_block  = var.public_outbound_acl_rules[count.index]["cidr_block"]
}

#######################
# outbound Network ACLs
#######################
resource "aws_network_acl" "outbound" {
  count = var.create_vpc && var.outbound_dedicated_network_acl && (length(var.outbound_subnets) > 0 || length(var.outbound_subnets_with_names) > 0) ? 1 : 0

  vpc_id     = element(concat(aws_vpc.this.*.id, [""]), 0)
  subnet_ids = ! var.subnet_with_names ? aws_subnet.outbound.*.id : aws_subnet.outbound_with_names.*.id

  tags = merge(
    {
      "Name" = format("%s-${var.outbound_subnet_suffix}", var.name)
    },
    var.tags,
    {
      Name        = format("%s-%s", var.tags["Name"], var.outbound_subnet_suffix)
      subnet_type = "outbound"
    },
    var.outbound_acl_tags,
  )
}

resource "aws_network_acl_rule" "outbound_inbound" {
  count = var.create_vpc && var.outbound_dedicated_network_acl && (length(var.outbound_subnets) > 0 || length(var.outbound_subnets_with_names) > 0) ? length(var.outbound_inbound_acl_rules) : 0

  network_acl_id = aws_network_acl.outbound[0].id

  egress      = false
  rule_number = var.outbound_inbound_acl_rules[count.index]["rule_number"]
  rule_action = var.outbound_inbound_acl_rules[count.index]["rule_action"]
  from_port   = lookup(var.outbound_inbound_acl_rules[count.index], "from_port", null)
  to_port     = lookup(var.outbound_inbound_acl_rules[count.index], "to_port", null)
  icmp_code   = lookup(var.outbound_inbound_acl_rules[count.index], "icmp_code", null)
  icmp_type   = lookup(var.outbound_inbound_acl_rules[count.index], "icmp_type", null)
  protocol    = var.outbound_inbound_acl_rules[count.index]["protocol"]
  cidr_block  = var.outbound_inbound_acl_rules[count.index]["cidr_block"]
}

resource "aws_network_acl_rule" "outbound_outbound" {
  count = var.create_vpc && var.outbound_dedicated_network_acl && (length(var.outbound_subnets) > 0 || length(var.outbound_subnets_with_names) > 0) ? length(var.outbound_outbound_acl_rules) : 0

  network_acl_id = aws_network_acl.outbound[0].id

  egress      = true
  rule_number = var.outbound_outbound_acl_rules[count.index]["rule_number"]
  rule_action = var.outbound_outbound_acl_rules[count.index]["rule_action"]
  from_port   = lookup(var.outbound_outbound_acl_rules[count.index], "from_port", null)
  to_port     = lookup(var.outbound_outbound_acl_rules[count.index], "to_port", null)
  icmp_code   = lookup(var.outbound_outbound_acl_rules[count.index], "icmp_code", null)
  icmp_type   = lookup(var.outbound_outbound_acl_rules[count.index], "icmp_type", null)
  protocol    = var.outbound_outbound_acl_rules[count.index]["protocol"]
  cidr_block  = var.outbound_outbound_acl_rules[count.index]["cidr_block"]
}

########################
# private Network ACLs
########################
resource "aws_network_acl" "private" {
  count = var.create_vpc && var.private_dedicated_network_acl && (length(var.private_subnets) > 0 || length(var.private_subnets_with_names) > 0) ? 1 : 0

  vpc_id     = element(concat(aws_vpc.this.*.id, [""]), 0)
  subnet_ids = ! var.subnet_with_names ? aws_subnet.private.*.id : aws_subnet.private_with_names.*.id

  tags = merge(
    {
      "Name" = format("%s-${var.private_subnet_suffix}", var.name)
    },
    var.tags,
    {
      Name        = format("%s-%s", var.tags["Name"], var.private_subnet_suffix)
      subnet_type = "private"
    },
    var.private_acl_tags,
  )
}

resource "aws_network_acl_rule" "private_inbound" {
  count = var.create_vpc && var.private_dedicated_network_acl && (length(var.private_subnets) > 0 || length(var.private_subnets_with_names) > 0) ? length(var.private_inbound_acl_rules) : 0

  network_acl_id = aws_network_acl.private[0].id

  egress      = false
  rule_number = var.private_inbound_acl_rules[count.index]["rule_number"]
  rule_action = var.private_inbound_acl_rules[count.index]["rule_action"]
  from_port   = lookup(var.private_inbound_acl_rules[count.index], "from_port", null)
  to_port     = lookup(var.private_inbound_acl_rules[count.index], "to_port", null)
  icmp_code   = lookup(var.private_inbound_acl_rules[count.index], "icmp_code", null)
  icmp_type   = lookup(var.private_inbound_acl_rules[count.index], "icmp_type", null)
  protocol    = var.private_inbound_acl_rules[count.index]["protocol"]
  cidr_block  = var.private_inbound_acl_rules[count.index]["cidr_block"]
}

resource "aws_network_acl_rule" "private_outbound" {
  count = var.create_vpc && var.private_dedicated_network_acl && (length(var.private_subnets) > 0 || length(var.private_subnets_with_names) > 0) ? length(var.private_outbound_acl_rules) : 0

  network_acl_id = aws_network_acl.private[0].id

  egress      = true
  rule_number = var.private_outbound_acl_rules[count.index]["rule_number"]
  rule_action = var.private_outbound_acl_rules[count.index]["rule_action"]
  from_port   = lookup(var.private_outbound_acl_rules[count.index], "from_port", null)
  to_port     = lookup(var.private_outbound_acl_rules[count.index], "to_port", null)
  icmp_code   = lookup(var.private_outbound_acl_rules[count.index], "icmp_code", null)
  icmp_type   = lookup(var.private_outbound_acl_rules[count.index], "icmp_type", null)
  protocol    = var.private_outbound_acl_rules[count.index]["protocol"]
  cidr_block  = var.private_outbound_acl_rules[count.index]["cidr_block"]
}


###########
# Defaults
###########
resource "aws_default_vpc" "this" {
  count = var.manage_default_vpc ? 1 : 0

  enable_dns_support   = var.default_vpc_enable_dns_support
  enable_dns_hostnames = var.default_vpc_enable_dns_hostnames
  enable_classiclink   = var.default_vpc_enable_classiclink

  tags = merge(
    {
      "Name" = format("%s", var.default_vpc_name)
    },
    var.tags,
    var.default_vpc_tags,
  )
}

