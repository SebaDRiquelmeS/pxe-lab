output "servidor_ip" {
  description = "IP del servidor en la red default"
  value       = try(data.libvirt_domain_interface_addresses.servidor.interfaces[0].addrs[0].addr, "unknown")
}

output "inventory_path" {
  description = "Ruta del inventario Ansible generado"
  value       = local_file.inventory.filename
}
