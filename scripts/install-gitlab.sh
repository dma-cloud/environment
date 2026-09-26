#!/bin/bash
# Модуль установки GitLab Community Edition (CE) в Namespace 'devops'
# С автоматическим подтягиванием паролей СУБД/Redis из пространства 'infra' и настройкой SMTP Яндекс

set -euo pipefail

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "====================================================="
echo "   Настройка и развертывание GitLab CE (devops)      "
echo "====================================================="

# 1. Проверяем наличие утилит
if ! command -v kubectl &> /dev/null; then
    echo "[ERROR] Утилита kubectl не найдена!"
    exit 1
fi

if ! command -v helm &> /dev/null; then
    echo "[ERROR] Утилита helm не найдена!"
    exit 1
fi

if ! command -v openssl &> /dev/null; then
    echo "[ERROR] Утилита openssl не найдена! Установите OpenSSL для генерации паролей."
    exit 1
fi

NAMESPACE="devops"
SECRET_NAME="gitlab-devops-secrets"
INFRA_SECRET="postgres-infra-secrets"
INFRA_NS="infra"

DB_HOST="postgres-infra-service.infra.svc.cluster.local"
REDIS_HOST="redis-infra-service.infra.svc.cluster.local"

# Функция для получения или генерации пароля (в случае если секреты создаются с нуля)
get_or_gen_password() {
    local prompt_text="$1"
    local user_input
    local generated_pass
    local choice

    printf '%s\n' "$prompt_text" >&2
    printf '%s\n' \
        "1) Сгенерировать надежный случайный пароль автоматически" \
        "2) Ввести пароль вручную" >&2
    printf '%s' "Выберите вариант (1 или 2): " >&2
    if ! IFS= read -r choice; then echo "[ERROR] Не удалось прочитать выбор." >&2; exit 1; fi

    if [ "$choice" = "1" ]; then
        generated_pass=$(openssl rand -base64 18)
        printf '%s\n' "$generated_pass"
    elif [ "$choice" = "2" ]; then
        printf '%s' "Введите пароль (символы скрыты): " >&2
        if ! IFS= read -r -s user_input; then echo "[ERROR] Не удалось прочитать пароль." >&2; exit 1; fi
        printf '\n' >&2
        if [ -z "$user_input" ]; then echo "[ERROR] Пароль не может быть пустым!" >&2; exit 1; fi
        printf '%s\n' "$user_input"
    else
        echo "[ERROR] Неверный выбор!" >&2; exit 1
    fi
}

# 2. Проверка и создание Namespace (до проверки секретов)
echo "[INFO] Проверка и создание пространства имен '${NAMESPACE}'..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# 3. Проверяем, существует ли уже секрет в пространстве devops
if kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" &> /dev/null; then
    echo "[INFO] Секрет '${SECRET_NAME}' уже существует в namespace '${NAMESPACE}'."
    echo "[INFO] Пропускаем интерактивный ввод данных. Будут использованы текущие секреты."
    
    # Извлекаем домен и логин из существующего секрета
    SMTP_USER=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.smtp-username}' | base64 --decode)
    GITLAB_DOMAIN=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.gitlab-domain}' 2>/dev/null || echo "lab")
else
    echo "[INFO] Секреты для GitLab не найдены. Запускается процесс настройки..."
    echo ""
    
    # Запрос домена
    printf '%s' "Введите базовый домен верхнего уровня для GitLab (например, lab): "
    if ! IFS= read -r GITLAB_DOMAIN; then echo "[ERROR] Ошибка чтения домена."; exit 1; fi
    GITLAB_DOMAIN=${GITLAB_DOMAIN:-"lab"}

    # Настройка SMTP Яндекс
    echo "[Настройка SMTP Яндекс]"
    printf '%s' "Введите email Яндекс (например, user@yandex.ru): "
    if ! IFS= read -r SMTP_USER; then echo "[ERROR] Не удалось прочитать Email."; exit 1; fi
    if [ -z "$SMTP_USER" ] || [[ ! "$SMTP_USER" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        echo "[ERROR] Введите корректный Email."; exit 1;
    fi

    printf '%s' "Введите пароль приложения Яндекс (символы скрыты): "
    if ! IFS= read -r -s SMTP_PASS; then echo "[ERROR] Не удалось прочитать пароль SMTP."; exit 1; fi
    printf '\n'
    if [ -z "$SMTP_PASS" ]; then echo "[ERROR] Пароль SMTP не может быть пустым."; exit 1; fi

    # АВТОМАТИЗАЦИЯ: Проверяем, есть ли готовый секрет инфраструктуры в пространстве infra
    if kubectl get secret "${INFRA_SECRET}" -n "${INFRA_NS}" &> /dev/null; then
        echo "[INFO] Найден существующий стек инфраструктуры в namespace '${INFRA_NS}'."
        echo "[INFO] Пароли СУБД, рута и Redis импортируются автоматически."
        
        DB_USER="gitlab"
        DB_NAME="gitlabhq_production"
        DB_PASS=$(kubectl get secret "${INFRA_SECRET}" -n "${INFRA_NS}" -o jsonpath='{.data.gitlab-db-password}' | base64 --decode)
        GITLAB_ROOT_PASS=$(kubectl get secret "${INFRA_SECRET}" -n "${INFRA_NS}" -o jsonpath='{.data.gitlab-root-password}' | base64 --decode)
        REDIS_PASS=$(kubectl get secret "${INFRA_SECRET}" -n "${INFRA_NS}" -o jsonpath='{.data.redis-password}' | base64 --decode)
    else
        # Если инфраструктурного секрета нет — запрашиваем всё вручную (фоллбэк-вариант)
        echo "[WARN] Секрет '${INFRA_SECRET}' в пространстве '${INFRA_NS}' не найден."
        echo "Пожалуйста, задайте параметры подключения вручную:"
        
        printf '%s' "Введите имя пользователя PostgreSQL [по умолчанию: gitlab]: "
        if ! IFS= read -r DB_USER; then echo "[ERROR] Ошибка чтения."; exit 1; fi
        DB_USER=${DB_USER:-"gitlab"}

        printf '%s' "Введите имя базы данных GitLab [по умолчанию: gitlabhq_production]: "
        if ! IFS= read -r DB_NAME; then echo "[ERROR] Ошибка чтения."; exit 1; fi
        DB_NAME=${DB_NAME:-"gitlabhq_production"}

        echo ""
        DB_PASS=$(get_or_gen_password "[База данных] Пароль пользователя СУБД $DB_USER:")
        GITLAB_ROOT_PASS=$(get_or_gen_password "[Администратор] Пароль root для веб-интерфейса GitLab:")
        REDIS_PASS=$(get_or_gen_password "[Кэш] Защитный пароль для инстанса Redis:")
    fi

    # Создаем безопасный секрет в пространстве devops
    echo ""
    echo "[INFO] Создание безопасных секретов в Kubernetes (namespace: ${NAMESPACE})..."
    kubectl create secret generic "$SECRET_NAME" \
      --namespace="$NAMESPACE" \
      --from-literal=smtp-username="$SMTP_USER" \
      --from-literal=smtp-password="$SMTP_PASS" \
      --from-literal=postgres-username="$DB_USER" \
      --from-literal=postgres-password="$DB_PASS" \
      --from-literal=postgres-database="$DB_NAME" \
      --from-literal=gitlab-root-password="$GITLAB_ROOT_PASS" \
      --from-literal=redis-password="$REDIS_PASS" \
      --from-literal=gitlab-domain="$GITLAB_DOMAIN" \
      --dry-run=client -o yaml | kubectl apply -f -
fi

# 4. Генерация временного конфигурационного файла values.yaml
VALUES_FILE=$(mktemp /tmp/gitlab-values.XXXXXX.yaml)

echo "[INFO] Генерируется конфигурационный манифест (values.yaml)..."
cat <<EOF > "$VALUES_FILE"
global:
  communityEdition: true
  hosts:
    domain: ${GITLAB_DOMAIN}

  # Использование глобального кластерного Ingress
  ingress:
    enabled: true
    configureCertmanager: false

  # Настройки почтового шлюза SMTP Яндекс
  email:
    from: "${SMTP_USER}"
    display_name: "GitLab DevOps"
    reply_to: "${SMTP_USER}"
  
  smtp:
    enabled: true
    address: "smtp.yandex.ru"
    port: 465
    user_name:
      secret: "${SECRET_NAME}"
      key: "smtp-username"
    password:
      secret: "${SECRET_NAME}"
      key: "smtp-password"
    starttls_auto: false
    tls: true
    authentication: "login"

  # Интеграция с внешней СУБД PostgreSQL из пространства infra
  psql:
    host: "${DB_HOST}"
    port: 5432
    database: "$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.postgres-database}' | base64 --decode)"
    username: "$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.postgres-username}' | base64 --decode)"
    password:
      secret: "${SECRET_NAME}"
      key: "postgres-password"

  # Интеграция с внешним Redis из пространства infra
  redis:
    host: "${REDIS_HOST}"
    port: 6379
    password:
      secret: "${SECRET_NAME}"
      key: "redis-password"

# Начальный пароль администратора (root) при первой инициализации
echo:
  initialRootPassword:
    secret: "${SECRET_NAME}"
    key: "gitlab-root-password"

# Отключаем встроенные зависимые стейтфул-компоненты чарта
postgresql:
  install: false

redis:
  install: false

nginx-ingress:
  enabled: false

certmanager:
  install: false
EOF

# 5. Развертывание стека через Helm
echo ""
echo "[INFO] Синхронизация официального репозитория GitLab Helm..."
helm repo add gitlab https://gitlab.io
helm repo update

echo "[INFO] Запуск атомарной установки/обновления чарта gitlab/gitlab-ce..."
helm upgrade --install gitlab gitlab/gitlab-ce \
    --namespace "${NAMESPACE}" \
    --values "$VALUES_FILE"

# Удаляем временную конфигурацию
rm -f "$VALUES_FILE"

echo ""
echo "[SUCCESS] Операция с GitLab Community Edition успешно завершена!"
echo "Для мониторинга подов используйте: kubectl get pods -n ${NAMESPACE} -w"