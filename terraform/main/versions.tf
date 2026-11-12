terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
  }

  required_version = "~>1.14.0"

  backend "s3" {
    endpoints = {
      s3 = "https://storage.yandexcloud.net"
    }
    bucket    = "tf-state-slov-2026"
    region    = "ru-central1"
    key       = "main/terraform.tfstate"

    skip_region_validation      = true
    skip_credentials_validation = true
    skip_s3_checksum            = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
  }
}

provider "yandex" {
  cloud_id                 = var.yc_cloud_id
  folder_id                = var.yc_folder_id
  zone                     = var.yc_zone
  service_account_key_file = var.yc_service_account_key_file
}
