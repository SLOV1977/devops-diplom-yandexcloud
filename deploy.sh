#!/usr/bin/env bash
#
# Развёртывание проекта с нуля в Яндекс.Облаке:
# bootstrap (СА + бакет стейта) -> infra (VPC + ВМ) -> k8s (свой ansible)
# -> kubeconfig -> local-path -> ingress-nginx -> kube-prometheus-stack -> devops-diplom-app
#
# Использование:
#   ./deploy.sh              # полный прогон
#   ./deploy.sh --skip-k8s   # кластер уже поднят — пропустить ansible
#   ./deploy.sh --skip-helm  # пропустить helm-установки
#
# Переменные окружения:
#   DOCKERHUB_USER   логин Docker Hub (для деплоя приложения)
#   APP_IMAGE        полный образ вида user/app:tag (по умолчанию DOCKERHUB_USER/devops-diplom-app:v1.0.0)
#   KUBECONF         путь к kubeconfig (по умолчанию ~/.kube/config)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_BOOTSTRAP="$ROOT_DIR/terraform/bootstrap"
TF_MAIN="$ROOT_DIR/terraform/main"
ANSIBLE_DIR="$ROOT_DIR/ansible"
K8S_CONFIG="$ROOT_DIR/k8s-config"
VALUES_TEMPLATE="$K8S_CONFIG/monitoring/kps-values.yaml.template"
RENDERED="/tmp/kps-values.rendered.yaml"

DOCKERHUB_USER="${DOCKERHUB_USER:-}"
APP_IMAGE="${APP_IMAGE:-${DOCKERHUB_USER:+$DOCKERHUB_USER/}devops-diplom-app:v1.0.0}"
KUBECONF="${KUBECONF:-$HOME/.kube/config}"

SKIP_K8S=false
SKIP_HELM=false
for arg in "$@"; do
  case "$arg" in
    --skip-k8s)  SKIP_K8S=true ;;
    --skip-helm) SKIP_HELM=true ;;
    *) echo "Неизвестный аргумент: $arg"; exit 1 ;;
  esac
done

log()  { echo -e "\n\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m  OK:\033[0m $*"; }
warn() { echo -e "\033[1;33m  !!\033[0m $*"; }
die()  { echo -e "\033[1;31m  ОШИБКА:\033[0m $*" >&2; exit 1; }

# Обёртки, чтобы kubeconfig не дублировать в каждой команде
K() { kubectl --kubeconfig "$KUBECONF" "$@"; }
H() { helm    --kubeconfig "$KUBECONF" "$@"; }

wait_for_nodes() {
  local timeout="${1:-900}" elapsed=0
  log "Ждём Ready от всех нод (макс $timeout с)..."
  while [ "$elapsed" -lt "$timeout" ]; do
    local ready total
    ready=$(K get nodes --no-headers 2>/dev/null | grep -c '\bReady\b' || true)
    total=$(K get nodes --no-headers 2>/dev/null | wc -l || true)
    if [ "$total" -gt 0 ] && [ "$ready" -eq "$total" ]; then
      ok "Все $total нод в состоянии Ready"
      return 0
    fi
    sleep 10; elapsed=$((elapsed + 10))
  done
  die "Ноды не стали Ready за $timeout секунд"
}

log "Проверка окружения"
for cmd in terraform kubectl helm jq ansible-playbook envsubst; do
  command -v "$cmd" >/dev/null || die "$cmd не найден. Установите и повторите."
done
[ -f "$ROOT_DIR/.authorized_key.json" ] \
  || die "Нет $ROOT_DIR/.authorized_key.json — положите ключ сервисного аккаунта в корень репозитория"
[ -n "$DOCKERHUB_USER" ] || warn "DOCKERHUB_USER не задан — деплой приложения будет пропущен"

# Не спрашивать подтверждение SSH-ключа при первом контакте с новыми ВМ
export ANSIBLE_HOST_KEY_CHECKING=False

# ── 1. Bootstrap ──────────────────────────────────────────────────
log "Шаг 1/7: Bootstrap (сервисный аккаунт + бакет стейта)"
cd "$TF_BOOTSTRAP"
if [ ! -d .terraform ]; then
  terraform init -input=false
fi
if [ ! -f "$TF_MAIN/terraform-infra-key.json" ]; then
  terraform apply -auto-approve -input=false
  terraform output -raw infra_authorized_key_json > "$TF_MAIN/terraform-infra-key.json"
  chmod 600 "$TF_MAIN/terraform-infra-key.json"
  ok "Создан СА terraform-infra, ключ сохранён в $TF_MAIN/"
else
  ok "bootstrap уже применён, ключ на месте"
fi

export AWS_ACCESS_KEY_ID="$(terraform output -raw state_access_key)"
export AWS_SECRET_ACCESS_KEY="$(terraform output -raw state_secret_key)"
BUCKET_NAME="$(terraform output -raw state_bucket)"
log "Бакет стейта: $BUCKET_NAME"

# ── 2. Main: VPC + ВМ ─────────────────────────────────────────────
log "Шаг 2/7: Основная инфраструктура (VPC + ВМ)"
cd "$TF_MAIN"
if [ ! -d .terraform ]; then
  sed -i.bak "s|tf-state-[a-zA-Z0-9._-]*\"$|${BUCKET_NAME}\"|" versions.tf
  rm -f versions.tf.bak
fi
terraform init -input=false
terraform apply -auto-approve -input=false
ok "Инфраструктура создана"

CP_EXTERNAL_IP=$(terraform output -json nodes | jq -r '.["cp-1"].external_ip')
WK_EXTERNAL_IP=$(terraform output -json nodes | jq -r '.["wk-1"].external_ip')
log "Внешний IP control-plane: $CP_EXTERNAL_IP"

# ── 3. Инвентарь ──────────────────────────────────────────────────
log "Шаг 3/7: Генерация ansible-инвентаря"
mkdir -p "$ANSIBLE_DIR/inventory/artifacts"
terraform -chdir="$TF_MAIN" output -raw ansible_inventory \
  > "$ANSIBLE_DIR/inventory/hosts.yaml"
ok "Инвентарь записан в ansible/inventory/hosts.yaml"

# ── 4. Kubernetes ─────────────────────────────────────────────────
if [ "$SKIP_K8S" = true ]; then
  warn "Пропускаю установку кластера (--skip-k8s)"
else
  log "Шаг 4/7: Установка Kubernetes (kubeadm + flannel)"
  cd "$ANSIBLE_DIR"
  ansible-playbook -i inventory/hosts.yaml playbook.yml -b -u ubuntu
  ok "Kubernetes установлен"
fi

# ── 5. kubeconfig ─────────────────────────────────────────────────
log "Шаг 5/7: Настройка kubeconfig"
if [ -f "$ANSIBLE_DIR/inventory/artifacts/admin.conf" ]; then
  mkdir -p "$(dirname "$KUBECONF")"
  cp "$ANSIBLE_DIR/inventory/artifacts/admin.conf" "$KUBECONF"
else
  warn "admin.conf не найден — если кластер ставили со skip, скопируйте kubeconfig руками"
fi
chmod 600 "$KUBECONF" || true
ok "kubeconfig готов (API: https://${CP_EXTERNAL_IP}:6443)"

wait_for_nodes 900
K get pods --all-namespaces || die "get pods --all-namespaces упал — проверьте статус кластера"
ok "kubectl get pods --all-namespaces отрабатывает без ошибок"

# ── 6. Helm-слой ──────────────────────────────────────────────────
if [ "$SKIP_HELM" = true ]; then
  warn "Пропускаю helm-установки (--skip-helm)"
else
  log "Шаг 6/7: local-path, ingress-nginx и kube-prometheus-stack"

  # 6.1. Хранилище для PVC (PVC в values ждут StorageClass local-path)
  if K get storageclass local-path >/dev/null 2>&1; then
    ok "local-path уже установлен"
  else
    K apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
    ok "local-path-provisioner установлен (для воспроизводимости лучше закоммитить манифест в репо)"
  fi

  # 6.2. Лейблы нод: контроллер ingress-nginx прижимается к воркерам
  #      через nodeSelector, чтобы ingress всегда жил на wk-1/wk-2
  log "Помечаю ноды лейблом role=control / role=worker"
  for node in $(K get nodes -o jsonpath='{.items[*].metadata.name}'); do
    case "$node" in
      cp-*) K label node "$node" role=control --overwrite ;;
      *)    K label node "$node" role=worker --overwrite ;;
    esac
  done
  ok "Лейблы нод проставлены"

  # 6.3. Репозитории
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update >/dev/null

  # 6.4. ingress-nginx (hostNetwork на воркерах — вход по IP ноды)
  H upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    -n ingress-nginx --create-namespace \
    --set controller.hostNetwork=true \
    --set controller.hostPort.enabled=true \
    --set controller.service.type=ClusterIP \
    --set controller.replicaCount=1 \
    --set controller.nodeSelector.role=worker \
    --set controller.admissionWebhooks.enabled=false
  ok "ingress-nginx установлен (hostNetwork, порт 80, только на воркерах)"

  # 6.5. kube-prometheus-stack из отрендеренного шаблона:
  # внешний IP wk-1 (нода с ingress) подставляется в root_url Grafana
  export GRAFANA_EXTERNAL_IP="$WK_EXTERNAL_IP"
  envsubst '${GRAFANA_EXTERNAL_IP}' < "$VALUES_TEMPLATE" > "$RENDERED"
  log "Grafana будет доступна на http://${GRAFANA_EXTERNAL_IP}/grafana/"

  H upgrade --install kps prometheus-community/kube-prometheus-stack \
    -n monitoring --create-namespace \
    -f "$RENDERED" --atomic
  ok "kube-prometheus-stack установлен из kps-values.yaml.template"

  K apply -f "$K8S_CONFIG/monitoring/grafana-ingress.yaml"
  ok "Grafana Ingress применён"

  for i in $(seq 1 30); do
    if K get pods -n ingress-nginx 2>/dev/null | grep -q '1/1.*Running'; then break; fi
    sleep 10
  done
fi

# ── 7. Приложение ─────────────────────────────────────────────────
log "Шаг 7/7: Деплой тестового приложения"
if [ -z "$DOCKERHUB_USER" ]; then
  warn "DOCKERHUB_USER не задан — пропускаю деплой. Задайте переменную и перезапустите."
else
  sed "s|image: APP_IMAGE|image: ${APP_IMAGE}|g" \
    "$K8S_CONFIG/app/manifests.yaml" > /tmp/manifests.yaml
  K apply -f /tmp/manifests.yaml
  ok "Манифесты приложения применены (namespace app, образ ${APP_IMAGE})"
fi

# ── Итоги ─────────────────────────────────────────────────────────
log "Готово. Сводка:"
echo "  Kubernetes API:   https://${CP_EXTERNAL_IP}:6443"
echo "  Приложение:       http://${WK_EXTERNAL_IP}/          (namespace: app)"
echo "  Grafana:          http://${WK_EXTERNAL_IP}/grafana/  (admin / см. kps-values)"
echo ""
echo "  kubeconfig:       $KUBECONF"
echo "  Инвентарь:        $ANSIBLE_DIR/inventory/hosts.yaml"
echo ""
echo "  Экономия купона — уничтожить всё:"
echo "    ./destroy.sh"
