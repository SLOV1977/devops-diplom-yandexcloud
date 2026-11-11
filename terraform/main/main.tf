data "yandex_compute_image" "ubuntu" {
  family = "ubuntu-2204-lts"
}

# ─── Сеть ────────────────────────────────────────────────
# Подсети во всех трёх зонах (требование задания: VPC с подсетями
# в разных зонах доступности).
resource "yandex_vpc_network" "k8s" {
  name = "k8s-network"
}

locals {
  subnets = {
    "ru-central1-a" = "10.0.1.0/24"
    "ru-central1-d" = "10.0.2.0/24"
    "ru-central1-e" = "10.0.3.0/24"
  }
}

resource "yandex_vpc_subnet" "k8s" {
  for_each = local.subnets

  name           = "k8s-subnet-${each.key}"
  zone           = each.key
  network_id     = yandex_vpc_network.k8s.id
  v4_cidr_blocks = [each.value]
}

# ─── Виртуальные машины ─────────────────────────────────
# control-plane не прерываемая: падение мастера = падение кластера.
# worker'ы — прерываемые, зоны задаются переменной worker_zones,
# core_fraction = 50 на standard-v3.
locals {
  control_plane = {
    "cp-1" = {
      zone        = "ru-central1-a"
      preemptible = false
      cores       = var.control_plane_flavor.cores
      memory      = var.control_plane_flavor.memory
    }
  }

  workers = {
    for i in range(var.worker_count) : "wk-${i + 1}" => {
      zone        = var.worker_zones[i % length(var.worker_zones)]
      preemptible = true
      cores       = var.worker_flavor.cores
      memory      = var.worker_flavor.memory
    }
  }

  nodes = merge(local.control_plane, local.workers)
}

resource "yandex_compute_instance" "node" {
  for_each = local.nodes

  name        = each.key
  hostname    = each.key
  zone        = each.value.zone
  platform_id = "standard-v3"   # Ice Lake: fraction 5/20/50/100, зоны a/d/e

  resources {
    cores         = each.value.cores
    memory        = each.value.memory
    core_fraction = 50
  }

  scheduling_policy {
    preemptible = each.value.preemptible
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu.image_id
      type     = "network-hdd"
      size     = 20
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.k8s[each.value.zone].id
    nat       = true
  }

  metadata = {
    user-data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
      vm_user = var.vm_user
      ssh_key = var.ssh_public_key
    })
  }
}

# ─── Outputs ─────────────────────────────────────────────
locals {
  node_output = {
    for name, vm in yandex_compute_instance.node : name => {
      internal_ip = vm.network_interface[0].ip_address
      external_ip = vm.network_interface[0].nat_ip_address
      zone        = vm.zone
      role        = startswith(name, "cp-") ? "kube_control_plane" : "kube_node"
    }
  }
}

output "nodes" {
  value = local.node_output
}

# Инвентарь для самописного ansible-плейбука:
# ansible_host — внешний IP (SSH с вашей машины),
# internal_ip — внутренний IP (кластерный трафик, ceritificates, join).
output "ansible_inventory" {
  value = yamlencode({
    all = {
      hosts = {
        for name, n in local.node_output : name => {
          ansible_host = n.external_ip
          internal_ip  = n.internal_ip
        }
      }

      children = {
        control = {
          hosts = { for name, n in local.node_output : name => null if n.role == "kube_control_plane" }
        }
        workers = {
          hosts = { for name, n in local.node_output : name => null if n.role == "kube_node" }
        }
      }
    }
  })
}
