output "vpc_compute_dns_zone_id" {
  value       = module.compute_dns_zone.zone_id
  description = "DNS zone id."
}

output "vpc_reverse_dns_zone_id" {
  value       = module.reverse_dns_zone.zone_id
  description = "Reverse Cloud DNS zone id."
}

output "vpc_storage_dns_zone_id" {
  value       = module.storage_dns_zone.zone_id
  description = "DNS zone id."
}
