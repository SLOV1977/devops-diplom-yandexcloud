#!/usr/bin/env bash
# Полное удаление: destroy сносит ВМ вместе с кластером.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_BOOTSTRAP="$ROOT_DIR/terraform/bootstrap"
TF_MAIN="$ROOT_DIR/terraform/main"

log() { echo -e "\n\033[1;34m==>\033[0m $*"; }

log "Уничтожение основной инфраструктуры (VPC + ВМ)"
cd "$TF_MAIN"

export AWS_ACCESS_KEY_ID="$(cd "$TF_BOOTSTRAP" && terraform output -raw state_access_key)"
export AWS_SECRET_ACCESS_KEY="$(cd "$TF_BOOTSTRAP" && terraform output -raw state_secret_key)"

terraform destroy -auto-approve -input=false
log "Основная инфраструктура удалена. Бакет и СА остаются."
log "Чтобы удалить и их: cd terraform/bootstrap && terraform destroy"
