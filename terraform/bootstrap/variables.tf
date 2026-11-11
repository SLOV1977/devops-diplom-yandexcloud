variable "yc_service_account_key_file" {
  description = "Путь к вашему authorized_key.json (только для bootstrap)"
  type        = string
}

variable "yc_cloud_id" {
  type = string
}

variable "yc_folder_id" {
  type = string
}

variable "tf_state_bucket_name" {
  description = "Глобально уникальное имя бакета для стейта"
  type        = string
}
