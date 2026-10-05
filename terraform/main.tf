terraform {
  required_version = ">= 1.0"
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.7"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

locals {
  images_path  = pathexpand("~/pxe-lab/images")
  ssh_key_pub  = file(pathexpand("~/pxe-lab/id_pxe.pub"))
  ssh_key_priv = pathexpand("~/pxe-lab/id_pxe")
  server_qcow2 = pathexpand("~/pxe-lab/images/server.qcow2")
}

# Pool que apunta al directorio de imágenes
resource "libvirt_pool" "pxe" {
  name = "pxe-lab"
  type = "dir"
  target = {
    path = local.images_path
  }
  create = {
    build     = true
    start     = true
    autostart = true
  }
  destroy = {
    delete = false
  }
}

# Red interna aislada, SIN DHCP de libvirt
resource "libvirt_network" "internal" {
  name      = "internal"
  autostart = true
  ips = [
    {
      address = "192.168.50.1"
      prefix  = 24
    }
  ]
  dns = {
    enable = "no"
  }
}

# Cloud-init del servidor
resource "libvirt_cloudinit_disk" "servidor_ci" {
  name      = "servidor-cloudinit"
  user_data = templatefile("${path.module}/user-data.yaml.tmpl", { ssh_key = local.ssh_key_pub })
  meta_data = yamlencode({
    instance-id    = "servidor"
    local-hostname = "servidor"
  })
  network_config = file("${path.module}/network-config.yaml")
}

# Subir el ISO cloud-init al pool de libvirt
resource "libvirt_volume" "servidor_ci_vol" {
  name = "servidor-cloudinit.iso"
  pool = libvirt_pool.pxe.name
  target = {
    format = {
      type = "iso"
    }
  }
  create = {
    content = {
      url = libvirt_cloudinit_disk.servidor_ci.path
    }
  }
}

# Disco vacío del cliente
resource "libvirt_volume" "cliente" {
  name     = "cliente.qcow2"
  pool     = libvirt_pool.pxe.name
  capacity = 20 * 1024 * 1024 * 1024
  target = {
    format = {
      type = "qcow2"
    }
  }
}

# Servidor PXE: 2 vCPU, 2 GB RAM, 2 NICs
resource "libvirt_domain" "servidor" {
  name      = "servidor"
  type      = "kvm"
  memory    = 2048
  memory_unit = "MiB"
  vcpu      = 2
  running   = true
  autostart = true

  os = {
    type = "hvm"
    arch = "x86_64"
  }

  features = {
    acpi = true
  }

  devices = {
    disks = [
      {
        device = "disk"
        driver = {
          name = "qemu"
          type = "qcow2"
        }
        source = {
          file = {
            file = local.server_qcow2
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
      },
      {
        device    = "cdrom"
        read_only = true
        source = {
          volume = {
            pool   = libvirt_pool.pxe.name
            volume = libvirt_volume.servidor_ci_vol.name
          }
        }
        target = {
          dev = "sda"
          bus = "sata"
        }
      }
    ]

    interfaces = [
      {
        type = "network"
        source = {
          network = {
            network = "default"
          }
        }
      },
      {
        type = "network"
        source = {
          network = {
            network = libvirt_network.internal.name
          }
        }
      }
    ]

    graphics = [
      {
        spice = {
          auto_port = true
          listen    = "127.0.0.1"
        }
      }
    ]
  }
}

# Cliente PXE: 2 vCPU, 4 GB RAM, 1 NIC en internal, boot red->disco, APAGADO tras apply
resource "libvirt_domain" "cliente" {
  name      = "cliente"
  type      = "kvm"
  memory    = 6144
  memory_unit = "MiB"
  vcpu      = 2
  running   = false
  autostart = false

  os = {
    type         = "hvm"
    arch         = "x86_64"
    boot_devices = [{ dev = "network" }, { dev = "hd" }]
  }

  # El orden de arranque lo gestiona scripts/pxe-install-client.sh
  lifecycle {
    ignore_changes = [os]
  }

  features = {
    acpi = true
  }

  devices = {
    disks = [
      {
        device = "disk"
        driver = {
          name = "qemu"
          type = "qcow2"
        }
        source = {
          volume = {
            pool   = libvirt_pool.pxe.name
            volume = libvirt_volume.cliente.name
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
      }
    ]

    interfaces = [
      {
        type = "network"
        source = {
          network = {
            network = libvirt_network.internal.name
          }
        }
      }
    ]

    graphics = [
      {
        spice = {
          auto_port = true
          listen    = "127.0.0.1"
        }
      }
    ]
  }
}

# Esperar a que el servidor arranque y obtenga IP por DHCP
resource "time_sleep" "wait_for_server_ip" {
  depends_on      = [libvirt_domain.servidor]
  create_duration = "120s"
}

# Consultar IPs del servidor tras el arranque
data "libvirt_domain_interface_addresses" "servidor" {
  depends_on = [time_sleep.wait_for_server_ip]
  domain     = libvirt_domain.servidor.name
  source     = "lease"
}

# Inventario Ansible generado automáticamente
resource "local_file" "inventory" {
  content = templatefile("${path.module}/inventory.ini.tmpl", {
    ip  = try(data.libvirt_domain_interface_addresses.servidor.interfaces[0].addrs[0].addr, "unknown")
    key = local.ssh_key_priv
  })
  filename        = pathexpand("~/pxe-lab/ansible/inventory.ini")
  file_permission = "0644"
}
