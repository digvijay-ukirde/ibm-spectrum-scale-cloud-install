/*
    Creates Azure Linux Virtual Machine with data disk
*/

variable "application_security_group_id" {}
variable "availability_zone" {}
variable "disks" {}
variable "dns_domain" {}
variable "forward_dns_zone" {}
variable "location" {}
variable "login_username" {}
variable "meta_private_key" {}
variable "meta_public_key" {}
variable "name_prefix" {}
variable "os_disk_caching" {}
variable "os_disk_encryption_set_id" {}
variable "os_storage_account_type" {}
variable "proximity_placement_group_id" {}
variable "resource_group_name" {}
variable "reverse_dns_zone" {}
variable "source_image_id" {}
variable "ssh_public_key_path" {}
variable "subnet_id" {}
variable "use_temporary_disks" {}
variable "vm_size" {}

data "template_file" "user_data" {
  template = <<EOF
#!/usr/bin/env bash
echo "${var.meta_private_key}" > ~/.ssh/id_rsa
chmod 600 ~/.ssh/id_rsa
echo "${var.meta_public_key}" >> ~/.ssh/authorized_keys
echo "StrictHostKeyChecking no" >> ~/.ssh/config
# Hostname settings
hostnamectl set-hostname --static "${var.name_prefix}.${var.dns_domain}"
echo "DOMAIN=\"${var.dns_domain}\"" >> "/etc/sysconfig/network-scripts/ifcfg-eth0"
systemctl restart NetworkManager
EOF
}

data "template_file" "lun_discover" {
  count    = var.use_temporary_disks == false ? 1 : 0
  template = <<EOF
#!/usr/bin/env bash
if [ ! -d "/var/mmfs/etc" ]; then
   mkdir -p "/var/mmfs/etc"
fi
echo "#!/bin/ksh" > "/var/mmfs/etc/nsddevices"
echo "# Generated by IBM Storage Scale deployment." >> "/var/mmfs/etc/nsddevices"
%{for i in range(0, 17)~}
echo "echo \"disk/azure/scsi1/lun${i} generic\"" >> "/var/mmfs/etc/nsddevices"
%{endfor~}
echo "# Bypass the NSD device discovery" >> "/var/mmfs/etc/nsddevices"
echo "return 0" >> "/var/mmfs/etc/nsddevices"
chmod u+x "/var/mmfs/etc/nsddevices"
EOF
}

data "template_file" "nvme_alias" {
  count    = var.use_temporary_disks ? 1 : 0
  template = <<EOF
#!/usr/bin/env bash
if [ ! -d "/var/mmfs/etc" ]; then
   mkdir -p "/var/mmfs/etc"
fi
echo "#!/bin/ksh" > "/var/mmfs/etc/nsddevices"
echo "# Generated by IBM Storage Scale deployment." >> "/var/mmfs/etc/nsddevices"
%{for i in range(0, 17)~}
echo "echo \"/dev/nvme${i}n1 generic\"" >> "/var/mmfs/etc/nsddevices"
%{endfor~}
echo "# Bypass the NSD device discovery" >> "/var/mmfs/etc/nsddevices"
echo "return 0" >> "/var/mmfs/etc/nsddevices"
chmod u+x "/var/mmfs/etc/nsddevices"
EOF
}

data "template_cloudinit_config" "user_data64" {
  count         = var.use_temporary_disks == false ? 1 : 0
  gzip          = true
  base64_encode = true
  part {
    content_type = "text/x-shellscript"
    content      = data.template_file.user_data.rendered
  }
  part {
    content_type = "text/x-shellscript"
    content      = try(data.template_file.lun_discover[0].rendered, null)
  }
}

data "template_cloudinit_config" "nvme_user_data64" {
  count         = var.use_temporary_disks ? 1 : 0
  gzip          = true
  base64_encode = true
  part {
    content_type = "text/x-shellscript"
    content      = data.template_file.user_data.rendered
  }
  part {
    content_type = "text/x-shellscript"
    content      = try(data.template_file.nvme_alias[0].rendered, null)
  }
}

resource "azurerm_network_interface" "itself" {
  name                = var.name_prefix
  location            = var.location
  resource_group_name = var.resource_group_name
  ip_configuration {
    name                          = var.name_prefix
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

# Create "A" (IPv4 Address) record to map IPv4 address as hostname along with domain
resource "azurerm_private_dns_a_record" "itself" {
  name                = var.name_prefix
  zone_name           = var.forward_dns_zone
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records             = azurerm_network_interface.itself.private_ip_addresses
  depends_on          = [azurerm_network_interface.itself]
}

# Create "PTR" (Pointer) to enable reverse DNS lookup, from an IP address to a hostname
resource "azurerm_private_dns_ptr_record" "itself" {
  # Considering only the first NIC private ip address
  name                = format("%s.%s.%s", split(".", azurerm_network_interface.itself.private_ip_addresses[0])[3], split(".", azurerm_network_interface.itself.private_ip_addresses[0])[2], split(".", azurerm_network_interface.itself.private_ip_addresses[0])[1])
  zone_name           = var.reverse_dns_zone
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records             = [format("%s.%s", var.name_prefix, var.dns_domain)]
  depends_on          = [azurerm_network_interface.itself]
}

resource "azurerm_network_interface_application_security_group_association" "associate_asg" {
  network_interface_id          = azurerm_network_interface.itself.id
  application_security_group_id = var.application_security_group_id
}

resource "azurerm_linux_virtual_machine" "itself" {
  name                         = var.name_prefix
  resource_group_name          = var.resource_group_name
  location                     = var.location
  size                         = var.vm_size
  admin_username               = var.login_username
  network_interface_ids        = [azurerm_network_interface.itself.id]
  proximity_placement_group_id = var.proximity_placement_group_id
  zone                         = var.availability_zone
  admin_ssh_key {
    username   = var.login_username
    public_key = file(var.ssh_public_key_path)
  }
  os_disk {
    caching                = var.os_disk_caching
    storage_account_type   = var.os_storage_account_type
    disk_encryption_set_id = var.os_disk_encryption_set_id
  }
  source_image_id = var.source_image_id
  custom_data     = var.use_temporary_disks ? data.template_cloudinit_config.nvme_user_data64[0].rendered : data.template_cloudinit_config.user_data64[0].rendered
  lifecycle {
    ignore_changes = all
  }
}

resource "azurerm_managed_disk" "itself" {
  for_each               = var.disks
  name                   = each.key
  location               = var.location
  create_option          = "Empty"
  disk_size_gb           = each.value["size"]
  resource_group_name    = var.resource_group_name
  storage_account_type   = each.value["type"]
  zone                   = azurerm_linux_virtual_machine.itself.zone
  disk_encryption_set_id = each.value["disk_encryption_set_id"]
}

resource "azurerm_virtual_machine_data_disk_attachment" "itself" {
  for_each           = azurerm_managed_disk.itself
  virtual_machine_id = azurerm_linux_virtual_machine.itself.id
  managed_disk_id    = azurerm_managed_disk.itself[each.key].id
  lun                = var.disks[each.key]["lun_no"]
  caching            = "ReadWrite"
}

output "instance_details" {
  value = {
    private_ip = azurerm_linux_virtual_machine.itself.private_ip_address
    id         = azurerm_linux_virtual_machine.itself.id
    dns        = format("%s.%s", var.name_prefix, var.dns_domain)
    zone       = var.availability_zone
  }
}
