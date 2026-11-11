provider "yandex" {
  service_account_key_file = var.yc_service_account_key_file
  cloud_id                 = var.yc_cloud_id
  folder_id                = var.yc_folder_id
}

# Сервисный аккаунт, от которого Terraform будет работать дальше
resource "yandex_iam_service_account" "infra" {
  name        = "terraform-infra"
  description = "Service account for Terraform infrastructure automation"
}

# Права: editor на папку (не admin)
resource "yandex_resourcemanager_folder_iam_member" "infra_editor" {
  folder_id = var.yc_folder_id
  role      = "editor"
  member    = "serviceAccount:${yandex_iam_service_account.infra.id}"
}

# Authorized key — им будет авторизоваться конфигурация main
resource "yandex_iam_service_account_key" "infra_auth_key" {
  service_account_id = yandex_iam_service_account.infra.id
  description        = "authorized key for terraform provider"
  depends_on         = [yandex_resourcemanager_folder_iam_member.infra_editor]
}

# Собираем authorized_key.json прямо в Terraform, чтобы вытащить через output
locals {
  infra_key_json = jsonencode({
    id                 = yandex_iam_service_account_key.infra_auth_key.id
    service_account_id = yandex_iam_service_account.infra.id
    created_at         = yandex_iam_service_account_key.infra_auth_key.created_at
    key_algorithm      = yandex_iam_service_account_key.infra_auth_key.key_algorithm
    public_key         = yandex_iam_service_account_key.infra_auth_key.public_key
    private_key        = yandex_iam_service_account_key.infra_auth_key.private_key
  })
}

# Статический ключ — только для S3-бэкенда
resource "yandex_iam_service_account_static_access_key" "infra_s3_key" {
  service_account_id = yandex_iam_service_account.infra.id
  description        = "static key for terraform state bucket"
  depends_on         = [yandex_resourcemanager_folder_iam_member.infra_editor]
}

resource "yandex_storage_bucket" "tf_state" {
  access_key = yandex_iam_service_account_static_access_key.infra_s3_key.access_key
  secret_key = yandex_iam_service_account_static_access_key.infra_s3_key.secret_key
  bucket     = var.tf_state_bucket_name

  anonymous_access_flags {
    read = false
    list = false
  }
  
  force_destroy = true
}

output "sa_name" {
  value = yandex_iam_service_account.infra.name
}

output "infra_authorized_key_json" {
  value     = local.infra_key_json
  sensitive = true
}

output "state_access_key" {
  value     = yandex_iam_service_account_static_access_key.infra_s3_key.access_key
  sensitive = true
}

output "state_secret_key" {
  value     = yandex_iam_service_account_static_access_key.infra_s3_key.secret_key
  sensitive = true
}

output "state_bucket" {
  value = yandex_storage_bucket.tf_state.bucket
}
