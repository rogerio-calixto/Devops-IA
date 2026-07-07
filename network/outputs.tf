output "vpc_id" {
  description = "ID da VPC provisionada."
  value       = aws_vpc.this.id
}

output "vpc_arn" {
  description = "ARN da VPC provisionada."
  value       = aws_vpc.this.arn
}

output "vpc_cidr_block" {
  description = "Bloco CIDR IPv4 da VPC."
  value       = aws_vpc.this.cidr_block
}

output "default_security_group_id" {
  description = "ID do security group default criado automaticamente pela VPC."
  value       = aws_vpc.this.default_security_group_id
}

output "default_route_table_id" {
  description = "ID da route table default criada automaticamente pela VPC."
  value       = aws_vpc.this.default_route_table_id
}

output "default_network_acl_id" {
  description = "ID da network ACL default criada automaticamente pela VPC."
  value       = aws_vpc.this.default_network_acl_id
}

output "public_subnet_ids" {
  description = "IDs das subnets públicas, indexados pelo nome declarado em vpc.public_subnets."
  value       = { for k, s in aws_subnet.public : k => s.id }
}

output "private_subnet_ids" {
  description = "IDs das subnets privadas, indexados pelo nome declarado em vpc.private_subnets."
  value       = { for k, s in aws_subnet.private : k => s.id }
}

output "internet_gateway_id" {
  description = "ID do Internet Gateway anexado à VPC."
  value       = aws_internet_gateway.this.id
}

output "nat_gateway_id" {
  description = "ID do NAT Gateway compartilhado (null se nat_gateway.enabled = false)."
  value       = try(aws_nat_gateway.this[0].id, null)
}

output "nat_gateway_public_ip" {
  description = "Endereço IPv4 público do NAT Gateway compartilhado (null se nat_gateway.enabled = false)."
  value       = try(aws_eip.nat[0].public_ip, null)
}

output "public_route_table_id" {
  description = "ID da route table pública."
  value       = aws_route_table.public.id
}

output "private_route_table_id" {
  description = "ID da route table privada."
  value       = aws_route_table.private.id
}
