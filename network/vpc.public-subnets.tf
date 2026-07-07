resource "aws_subnet" "public" {
  for_each = { for s in var.vpc.public_subnets : s.name => s }

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr_block
  availability_zone       = each.value.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project.name}-${var.project.environment}-${each.value.name}"
    Tier = "public"
  }
}
