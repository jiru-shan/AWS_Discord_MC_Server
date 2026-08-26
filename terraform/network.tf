data "aws_subnet" "selected" {
  id = local.subnet_id
}

resource "aws_security_group" "server" {
  name        = "${local.name}-server"
  description = "On-demand Minecraft server"
  vpc_id      = data.aws_vpc.selected.id

  tags = {
    Name = "${local.name}-server"
  }
}

resource "aws_vpc_security_group_ingress_rule" "minecraft" {
  for_each = toset(var.allowed_cidrs)

  security_group_id = aws_security_group.server.id
  description       = "Minecraft (Java Edition)"
  cidr_ipv4         = each.value
  from_port         = var.server_port
  to_port           = var.server_port
  ip_protocol       = "tcp"
}

# Off by default. SSM Session Manager gives a root shell over the AWS API with
# no inbound port and no key material, which is both easier and safer.
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = var.enable_ssh ? toset(var.ssh_allowed_cidrs) : toset([])

  security_group_id = aws_security_group.server.id
  description       = "SSH"
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

# Outbound is wide open on purpose: the instance has to reach Mojang, Fabric,
# the package mirrors and several AWS endpoints.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.server.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
