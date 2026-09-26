#!/bin/bash
# Модуль установки GitLab Community Edition (CE) в Namespace 'devops'
# С подключением внешних PostgreSQL и Redis из пространства 'infra', а также SMTP Яндекс

set -e

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== Настройка и развертывание GitLab CE (Инфра-режим) ===${NC}"

# 1. Проверка утилит
for cmd in kubectl helm; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "${RED}Ошибка: утилита $cmd не установлена.${NC}"
        exit 1
    fi
done

NAMESPACE="devops"
SECRET_NAME="gitlab-devops-secrets"
DB_HOST="postgres-infra-service.infra.svc.cluster.local"
REDIS_HOST="redis-infra-service.infra.svc.cluster.local"

# Создаем/проверяем Namespace заранее, чтобы kubectl get secret не падал, если пространства нет
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# 2. ПРОВЕРКА: Существует ли уже секрет с паролями?
if kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" &> /dev/null; then
    echo -e "${GREEN}Секрет '${SECRET_NAME}' уже существует в namespace '${NAMESPACE}'. Пропускаем ввод паролей.${NC}"
    
    # Извлекаем сохраненный SMTP_USER из секрета для подстановки в блок email.from в values.yaml
    echo -e "${YELLOW}Извлекаем почтовый логин из существующего секрета...${NC}"
    SMTP_USER=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.smtp-username}' | base64 --decode)
    
    # Проверяем, был ли в секрете сохранен пароль от Redis
    HAS_REDIS_PASS=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.redis-password}' 2>/dev/null || true)
else
    echo -e "${YELLOW}Секрет '${SECRET_NAME}' не найден. Запускаем интерактивную настройку...${NC}"

    # 3. Интерактивный запрос данных для SMTP Яндекс
    echo -e "${YELLOW}--- Настройка SMTP Яндекс ---${NC}"
    read -p "Введите email Яндекс (например, user@yandex.ru): " SMTP_USER
    if [ -z "$SMTP_USER" ]; then echo -e "${RED}Ошибка: Логин пустой.${NC}"; exit 1; fi

    stty -echo
    read -p "Введите пароль приложения Яндекс: " SMTP_PASS
    stty echo
    echo ""

    # 4. Интерактивный запрос данных для PostgreSQL (infra)
    echo -e "${YELLOW}--- Настройка внешней PostgreSQL ---${NC}"
    read -p "Введите имя пользователя PostgreSQL [по умолчанию: gitlab]: " DB_USER
    DB_USER=${DB_USER:-"gitlab"}

    read -p "Введите имя базы данных GitLab [по умолчанию: gitlabhq_production]: " DB_NAME
    DB_NAME=${DB_NAME:-"gitlabhq_production"}

    stty -echo
    read -p "Введите пароль для пользователя базы данных $DB_USER: " DB_PASS
    stty echo
    echo ""
    if [ -z "$DB_PASS" ]; then echo -e "${RED}Ошибка: Пароль БД не может быть пустым.${NC}"; exit 1; fi

    # 5. Интерактивный запрос данных для Redis (infra)
    echo -e "${YELLOW}--- Настройка внешнего Redis ---${NC}"
    echo -e "${YELLOW}Если Redis работает без пароля, просто нажмите Enter${NC}"
    stty -echo
    read -p "Введите пароль для Redis (если есть): " REDIS_PASS
    stty echo
    echo ""

    # 6. Создание секретов gitlab-devops-secrets
    echo -e "${GREEN}Создание Kubernetes секрета ${SECRET_NAME}...${NC}"

    SECRET_CMD="kubectl create secret generic ${SECRET_NAME} \
        --namespace=${NAMESPACE} \
        --from-literal=smtp-username=\"${SMTP_USER}\" \
        --from-literal=smtp-password=\"${SMTP_PASS}\" \
        --from-literal=postgres-username=\"${DB_USER}\" \
        --from-literal=postgres-password=\"${DB_PASS}\" \
        --from-literal=postgres-database=\"${DB_NAME}\""

    # ИСПРАВЛЕНО: Правильный синтаксис проверки флага непустой строки (-n)
    if [ -n "$REDIS_PASS" ]; then
        SECRET_CMD="${SECRET_CMD} --from-literal=redis-password=\"${REDIS_PASS}\""
        HAS_REDIS_PASS="yes"
    else
        HAS_REDIS_PASS=""
    fi

    eval "${SECRET_CMD} --dry-run=client -o yaml" | kubectl apply -f -
fi

# 7. Генерация временного values.yaml для Helm
VALUES_FILE=$(mktemp /tmp/gitlab-values.XXXXXX.yaml)

echo -e "${GREEN}Генерация конфигурации Helm (values.yaml)...${NC}"
cat <<EOF > "$VALUES_FILE"
global:
  communityEdition: true
  hosts:
    domain: lab

  # Внешний существующий Ingress кластера
  ingress:
    enabled: true
    configureCertmanager: false

  # Почта через SMTP Яндекса
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

  # НАСТРОЙКА ПОДКЛЮЧЕНИЯ К ВНЕШНЕЙ POSTGRESQL (infra)
  psql:
    host: "${DB_HOST}"
    port: 5432
    # Имя базы и юзера чарт ожидает строками, но пароль строго через секрет
    database: "$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.postgres-database}' | base64 --decode)"
    username: "$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.postgres-username}' | base64 --decode)"
    password:
      secret: "${SECRET_NAME}"
      key: "postgres-password"

  # НАСТРОЙКА ПОДКЛЮЧЕНИЯ К ВНЕШНЕМУ REDIS (infra)
  redis:
    host: "${REDIS_HOST}"
    port: 6379
EOF

# ИСПРАВЛЕНО: Корректная проверка флага существования пароля Redis
if [ -n "$HAS_REDIS_PASS" ]; then
cat <<EOF >> "$VALUES_FILE"
    password:
      secret: "${SECRET_NAME}"
      key: "redis-password"
EOF
fi

# Дописываем блоки отключения зависимостей в values.yaml
cat <<EOF >> "$VALUES_FILE"

# Отключаем встроенную PostgreSQL
postgresql:
  install: false

# Отключаем встроенный Redis
redis:
  install: false

# ПОЛНОСТЬЮ ОТКЛЮЧАЕМ встроенный Nginx Ingress Controller
nginx-ingress:
  enabled: false

# Выключаем встроенный cert-manager
certmanager:
  install: false
EOF

# 8. Развертывание через Helm
echo -e "${GREEN}Обновление репозиториев Helm...${NC}"
# ИСПРАВЛЕНО: Указан правильный URL официального Helm-репозитория GitLab
helm repo add gitlab https://charts.gitlab.io/
helm repo update

echo -e "${GREEN}Запуск установки/обновления GitLab CE в неймспейс ${NAMESPACE}...${NC}"
helm upgrade --install gitlab gitlab/gitlab-ce  \
    --namespace ${NAMESPACE} \
    --values "$VALUES_FILE"

# Удаляем временный файл конфигурации
rm -f "$VALUES_FILE"

echo -e "${GREEN}=== Операция с GitLab CE успешно завершена! ===${NC}"
echo -e "Следить за подом: ${YELLOW}kubectl get pods -n ${NAMESPACE} -w${NC}"