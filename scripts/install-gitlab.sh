#!/bin/bash
# Модуль установки GitLab Community Edition (CE) в Namespace 'devops'
# ИСПОЛЬЗУЮТСЯ ТОЛЬКО ЧИСТЫЕ KUBERNETES MANIFESTS (БЕЗ HELM И SUBPATH БАГОВ)

set -euo pipefail

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "====================================================="
echo "   Настройка GitLab CE через ConfigMap для k3s       "
echo "====================================================="

# 1. Проверяем наличие утилит
if ! command -v kubectl &> /dev/null; then
    echo "[ERROR] Утилита kubectl не найдена!"
    exit 1
fi

NAMESPACE="devops"
SECRET_NAME="gitlab-devops-secrets"
INFRA_SECRET="postgres-infra-secrets"
INFRA_NS="infra"

DB_HOST="postgres-infra-service.infra.svc.cluster.local"
REDIS_HOST="redis-infra-service.infra.svc.cluster.local"

# 2. Проверка и создание Namespace
echo "[INFO] Проверка пространства имен '${NAMESPACE}'..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# 3. Синхронизация и автоматический импорт секретов из infra
if kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" &> /dev/null; then
    echo "[INFO] Секрет '${SECRET_NAME}' уже существует. Извлекаем данные для деплоя..."
    
    GITLAB_DOMAIN=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.gitlab-domain}' | base64 --decode)
    SMTP_USER=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.smtp-username}' | base64 --decode)
    SMTP_PASS=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.smtp-password}' | base64 --decode)
    DB_USER=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.postgres-username}' | base64 --decode)
    DB_NAME=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.postgres-database}' | base64 --decode)
    DB_PASS=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.postgres-password}' | base64 --decode)
    REDIS_PASS=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.redis-password}' | base64 --decode)
else
    echo "[INFO] Секреты не найдены. Запускается импорт данных из пространства '${INFRA_NS}'..."
    
    printf '%s' "Введите базовый домен для GitLab (например, gitlab.lab): "
    if ! IFS= read -r GITLAB_DOMAIN; then echo "[ERROR] Ошибка чтения."; exit 1; fi
    GITLAB_DOMAIN=${GITLAB_DOMAIN:-"gitlab.lab"}

    # Проверяем наличие инфраструктурного секрета
    if kubectl get secret "${INFRA_SECRET}" -n "${INFRA_NS}" &> /dev/null; then
        echo "[INFO] Успешно найден '${INFRA_SECRET}'. Импортируем пароли СУБД и Redis..."
        
        DB_USER="gitlab"
        DB_NAME="gitlabhq_production"
        
        DB_PASS=$(kubectl get secret "${INFRA_SECRET}" -n "${INFRA_NS}" -o jsonpath='{.data.gitlab-db-password}' | base64 --decode)
        REDIS_PASS=$(kubectl get secret "${INFRA_SECRET}" -n "${INFRA_NS}" -o jsonpath='{.data.redis-password}' | base64 --decode)
        
        # Интерактивный запрос почты Яндекса (так как в БД её нет)
        printf '%s' "Введите email Яндекс для SMTP (например, user@yandex.ru): "
        if ! IFS= read -r SMTP_USER; then echo "[ERROR] Ошибка чтения."; exit 1; fi
        
        printf '%s' "Введите пароль приложения Яндекс SMTP (символы скрыты): "
        if ! IFS= read -r -s SMTP_PASS; then echo "[ERROR] Ошибка чтения."; exit 1; fi
        printf '\n'
        
        # Создаем спаренный секрет в пространстве devops
        kubectl create secret generic "$SECRET_NAME" \
          --namespace="$NAMESPACE" \
          --from-literal=smtp-username="$SMTP_USER" \
          --from-literal=smtp-password="$SMTP_PASS" \
          --from-literal=postgres-username="$DB_USER" \
          --from-literal=postgres-password="$DB_PASS" \
          --from-literal=postgres-database="$DB_NAME" \
          --from-literal=redis-password="$REDIS_PASS" \
          --from-literal=gitlab-domain="$GITLAB_DOMAIN" \
          --dry-run=client -o yaml | kubectl apply -f -
    else
        echo "[ERROR] Секрет базы данных '${INFRA_SECRET}' в пространстве '${INFRA_NS}' не найден!"
        echo "Сначала разверните базовую инфраструктуру postgres/redis."
        exit 1
    fi
fi

# 4. Применяем конфигурацию и декларативные манифесты K8s
echo "[INFO] Применение манифестов GitLab CE в Kubernetes..."

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: gitlab-config
  namespace: ${NAMESPACE}
data:
  # Файл конфигурации ядра GitLab
  gitlab.rb: |
    external_url 'http://${GITLAB_DOMAIN}'
    
    # Отключение встроенных баз и кэша (Твое ключевое требование)
    postgresql['enable'] = false
    redis['enable'] = false
    
    # Настройка веб-сервера под Ingress контроллер
    nginx['listen_port'] = 80
    nginx['listen_https'] = false
    
    # Подключение к PostgreSQL в пространстве infra
    gitlab_rails['db_adapter'] = 'postgresql'
    gitlab_rails['db_encoding'] = 'utf8'
    gitlab_rails['db_host'] = '${DB_HOST}'
    gitlab_rails['db_port'] = 5432
    gitlab_rails['db_username'] = '${DB_USER}'
    gitlab_rails['db_database'] = '${DB_NAME}'
    gitlab_rails['db_password'] = ENV['DB_PASSWORD']
    
    # Подключение к защищенному Redis в пространстве infra
    gitlab_rails['redis_host'] = '${REDIS_HOST}'
    gitlab_rails['redis_port'] = 6379
    gitlab_rails['redis_password'] = ENV['REDIS_PASSWORD']
    
    # Настройка почтового шлюза SMTP Яндекс
    gitlab_rails['smtp_enable'] = true
    gitlab_rails['smtp_address'] = "smtp.yandex.ru"
    gitlab_rails['smtp_port'] = 465
    gitlab_rails['smtp_tls'] = true
    gitlab_rails['smtp_verify_mode'] = "none"
    gitlab_rails['smtp_authentication'] = "login"
    gitlab_rails['smtp_user_name'] = ENV['SMTP_USER']
    gitlab_rails['smtp_password'] = ENV['SMTP_PASSWORD']
    gitlab_rails['gitlab_email_from'] = ENV['SMTP_USER']
    gitlab_rails['gitlab_email_reply_to'] = ENV['SMTP_USER']

    # ОПТИМИЗАЦИЯ ДЛЯ КЛАСТЕРА K3S (Тюнинг лимитов под домашнюю лабораторную зону)
    puma['worker_processes'] = 2
    puma['min_threads'] = 2
    puma['max_threads'] = 4
    sidekiq['max_concurrency'] = 10
    
    # Отключение тяжелых встроенных экспортеров мониторинга ради экономии ресурсов хоста
    prometheus_monitoring['enable'] = false
    alertmanager['enable'] = false
    node_exporter['enable'] = false
    redis_exporter['enable'] = false
    postgres_exporter['enable'] = false
    gitlab_exporter['enable'] = false
    grafana['enable'] = false
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: gitlab-data-pvc
  namespace: ${NAMESPACE}
spec:
  storageClassName: local-path
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gitlab-ce
  namespace: ${NAMESPACE}
  labels:
    app: gitlab-ce
spec:
  replicas: 1
  # Стратегия Recreate жестко очищает старые поды перед стартом новых
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: gitlab-ce
  template:
    metadata:
      labels:
        app: gitlab-ce
    spec:
      containers:
      - name: gitlab-ce
        image: gitlab/gitlab-ce:latest
        ports:
        - containerPort: 80
          name: http
        - containerPort: 22
          name: ssh
        # Безопасный инжект секретных токенов в переменные среды ОС контейнера
        env:
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: ${SECRET_NAME}
              key: postgres-password
        - name: REDIS_PASSWORD
          valueFrom:
            secretKeyRef:
              name: ${SECRET_NAME}
              key: redis-password
        - name: SMTP_USER
          valueFrom:
            secretKeyRef:
              name: ${SECRET_NAME}
              key: smtp-username
        - name: SMTP_PASSWORD
          valueFrom:
            secretKeyRef:
              name: ${SECRET_NAME}
              key: smtp-password
        resources:
          limits:
            memory: 3.5Gi
          requests:
            memory: 1.8Gi
        volumeMounts:
        # ИСПРАВЛЕНО: Монтируем всю директорию ConfigMap целиком без использования subPath
        - name: gitlab-config-volume
          mountPath: /etc/gitlab
        - mountPath: /var/opt/gitlab
          name: gitlab-data
      volumes:
      - name: gitlab-config-volume
        configMap:
          name: gitlab-config
      - name: gitlab-data
        persistentVolumeClaim:
          claimName: gitlab-data-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: gitlab-ce-service
  namespace: ${NAMESPACE}
spec:
  ports:
  - port: 80
    targetPort: 80
    name: http
  - port: 22
    targetPort: 22
    name: ssh
  selector:
    app: gitlab-ce
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gitlab-ingress
  namespace: ${NAMESPACE}
spec:
  rules:
  - host: ${GITLAB_DOMAIN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: gitlab-ce-service
            port:
              number: 80
EOF

echo ""
echo -e "${GREEN}[SUCCESS] Манифесты успешно обновлены и применены в namespace '${NAMESPACE}'!${NC}"
echo -e "Для отслеживания логов инициализации используй коду:"
echo -e "${YELLOW}kubectl logs -n ${NAMESPACE} -l app=gitlab-ce -f${NC}"