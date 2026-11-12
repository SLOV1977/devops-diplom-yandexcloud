# ─── Сервисный аккаунт: ищем созданный в bootstrap по имени ──
# Напрямую сослаться на ресурс из другого state нельзя,
# поэтому связываемся по имени.
data "yandex_iam_service_account" "restarter" {
  name = "terraform-infra"
}

# ─── Zip с кодом функции ─────────────────────────────────
data "archive_file" "restart_fn" {
  type        = "zip"
  source_dir  = "${path.module}/function"
  output_path = "${path.module}/restart-fn.zip"
}

# ─── Функция автозапуска: по одной на каждый воркер ──────
resource "yandex_function" "restart_worker" {
  for_each = {
    for name, vm in yandex_compute_instance.node :
    name => vm if startswith(name, "wk-")
  }

  name               = "restart-${each.key}"
  runtime            = "nodejs22"
  entrypoint         = "index.handler"
  memory             = 128
  execution_timeout  = 5
  service_account_id = data.yandex_iam_service_account.restarter.id
  user_hash          = data.archive_file.restart_fn.output_md5

  content {
    zip_filename = data.archive_file.restart_fn.output_path
  }

  environment = {
    INSTANCE_ID = each.value.id
  }
}

# ─── Триггер-таймер: раз в минуту на каждый воркер ───────
resource "yandex_function_trigger" "restart_timer" {
  for_each = {
    for name, vm in yandex_compute_instance.node :
    name => vm if startswith(name, "wk-")
  }

  name = "restart-${each.key}-timer"

  timer {
    cron_expression = "* * * * ? *"
  }

  function {
    id                 = yandex_function.restart_worker[each.key].id
    service_account_id = data.yandex_iam_service_account.restarter.id
  }
}
