variable "yc_service_account_key_file" {
  description = "Путь к authorized_key.json СА terraform-infra (относительно terraform/main)"
  type        = string
  default     = "terraform-infra-key.json"
}

variable "yc_cloud_id"  { type = string }
variable "yc_folder_id" { type = string }

variable "yc_zone" {
  type    = string
  default = "ru-central1-a"
}

variable "worker_zones" {
  description = "Зоны для worker-нод (ротация по кругу)"
  type        = list(string)
  default     = ["ru-central1-d", "ru-central1-e"]
}

variable "ssh_public_key" {
  description = "Содержимое ~/.ssh/id_ed25519.pub"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Путь к приватному ключу на машине, откуда запускается kubespray"
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "vm_user" {
  type    = string
  default = "ubuntu"
}

variable "control_plane_flavor" {
  type = object({
    cores  = number
    memory = number
  })
  default = {
    cores  = 2
    memory = 4
  }
}

variable "worker_flavor" {
  type = object({
    cores  = number
    memory = number
  })
  default = {
    cores  = 2
    memory = 4
  }
}

variable "worker_count" {
  type    = number
  default = 2
}
