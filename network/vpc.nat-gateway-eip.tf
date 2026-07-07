resource "aws_eip" "nat" {
  count = var.nat_gateway.enabled ? 1 : 0

  domain = "vpc"

  tags = {
    Name = "${var.project.name}-${var.project.environment}-nat-eip"
  }

  depends_on = [aws_internet_gateway.this]
}
