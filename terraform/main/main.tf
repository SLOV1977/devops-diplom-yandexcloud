data "yandex_compute_image" "ubuntu" {
  family = "ubuntu-2204-lts"
}

# ─── Сеть ────────────────────────────────────────────────
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

# Control-plane — обычная ВМ: закрепляем статический IP напрямую.
resource "yandex_vpc_address" "control_plane" {
  name = "k8s-cp-ip"
  external_ipv4_address {
    zone_id = "ru-central1-a"
  }
}

# Прерываемым ВМ закрепить IP нельзя, поэтому «лицо» кластера —
# NLB со своим выделенным адресом. Адрес живёт, пока жив ресурс,
# независимо от состояния прерываемых воркеров.
resource "yandex_vpc_address" "ingress" {
  name = "k8s-ingress-ip"
  external_ipv4_address {
    zone_id = "ru-central1-a"
  }
}

# ─── Виртуальные машины ──────────────────────────────────
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
    nat_ip_address = startswith(each.key, "cp-") ? yandex_vpc_address.control_plane.external_ipv4_address[0].address : null
  }

  metadata = {
    user-data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
      vm_user = var.vm_user
      ssh_key = var.ssh_public_key
    })
  }

  # при замене прерываемой ноды сначала создать новую,
  # потом удалить старую (меньше простоя таргетов NLB)
  lifecycle {
    create_before_destroy = true
  }
}

# ───────── NLB → NodePort ingress-nginx ─────────────────
# Таргеты — внутренние IP воркеров: сохраняются при остановке ВМ,
# а при замене ВМ Terraform обновит их сам.
# dynamic "target" покрывает любое количество воркеров
resource "yandex_lb_target_group" "ingress" {
  name      = "k8s-ingress-tg"
  region_id = "ru-central1"

  dynamic "target" {
    for_each = {
      for name, vm in yandex_compute_instance.node :
      name => vm if startswith(name, "wk-")
    }

    content {
      subnet_id = yandex_vpc_subnet.k8s[target.value.zone].id
      address   = target.value.network_interface[0].ip_address
    }
  }
}

resource "yandex_lb_network_load_balancer" "ingress" {
  name      = "k8s-ingress-nlb"
  region_id = "ru-central1"
  type      = "external"

  listener {
    name        = "http"
    port        = 80
    target_port = 30080          # NodePort ingress-nginx

    external_address_spec {
      address = yandex_vpc_address.ingress.external_ipv4_address[0].address
    }
  }

  attached_target_group {
    target_group_id = yandex_lb_target_group.ingress.id

    healthcheck {
      name                = "http-health"
      interval            = 10
      timeout             = 5
      healthy_threshold   = 2
      unhealthy_threshold = 3

      http_options {
        port = 30080
        path = "/healthz"
      }
    }
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

  ansible_inventory_yaml = yamlencode({
    all = {
      vars = {
        ansible_user = var.vm_user
      }
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

output "nodes" {
  value = local.node_output
}

output "ansible_inventory" {
  value = local.ansible_inventory_yaml
}

output "ingress_external_ip" {
  value = yandex_vpc_address.ingress.external_ipv4_address[0].address
}

# ─── Автообновление инвентаря Ansible ────────────────────
# Инвентарь пишется в файл при каждом изменении состава/адресов
# ВМ — ручной шаг «terraform output > hosts.yaml» больше не нужен.
resource "local_file" "ansible_inventory" {
  content         = local.ansible_inventory_yaml
  filename        = "${path.module}/../ansible/inventory/hosts.yaml"
  file_permission = "0644"
}
