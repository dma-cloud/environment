#!/bin/bash
# Модуль установки GitLab Community Edition (CE) в Namespace 'devops'
# Оптимизировано под k3s архитектуру и экономию RAM

set -euo pipefail

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "====================================================="
echo "   Настройка GitLab CE через ConfigMap для k3s       "
echo "====================================================="

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

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

if kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" &> /dev/null; then
    echo "[INFO] Секрет '${SECRET_NAME}' существует. Извлекаем данные..."
    GITLAB_DOMAIN=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.gitlab-domain}' | base64 --decode)
    SMTP_USER=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.smtp-username}' | base64 --decode)
    SMTP_PASS=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.smtp-password}' | base64 --decode)
    DB_USER=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.postgres-username}' | base64 --decode)
    DB_NAME=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.postgres-database}' | base64 --decode)
    DB_PASS=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.postgres-password}' | base64 --decode)
    REDIS_PASS=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.redis-password}' | base64 --decode)
else
    echo "[INFO] Секреты не найдены. Импортируем из '${INFRA_NS}'..."
    printf '%s' "Введите базовый домен для GitLab (например, gitlab.lab): "
    if ! IFS= read -r GITLAB_DOMAIN; then echo "[ERROR] Ошибка чтения."; exit 1; fi
    GITLAB_DOMAIN=${GITLAB_DOMAIN:-"gitlab.lab"}

    if kubectl get secret "${INFRA_SECRET}" -n "${INFRA_NS}" &> /dev/null; then
        DB_USER="gitlab"
        DB_NAME="gitlabhq_production"
        DB_PASS=$(kubectl get secret "${INFRA_SECRET}" -n "${INFRA_NS}" -o jsonpath='{.data.gitlab-db-password}' | base64 --decode)
        REDIS_PASS=$(kubectl get secret "${INFRA_SECRET}" -n "${INFRA_NS}" -o jsonpath='{.data.redis-password}' | base64 --decode)
        
        printf '%s' "Введите email Яндекс для SMTP: "
        if ! IFS= read -r SMTP_USER; then echo "[ERROR] Ошибка."; exit 1; fi
        printf '%s' "Введите пароль приложения Яндекс SMTP: "
        if ! IFS= read -r -s SMTP_PASS; then echo "[ERROR] Ошибка."; exit 1; fi
        printf '\n'
        
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
        echo "[ERROR] Секрет '${INFRA_SECRET}' не найден."
        exit 1
    fi
fi

echo "[INFO] Применение манифестов GitLab CE..."

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: gitlab-config
  namespace: ${NAMESPACE}
data:
  gitlab.rb: |
    external_url 'http://${GITLAB_DOMAIN}'
    
    postgresql['enable'] = false
    redis['enable'] = false
    
    nginx['listen_port'] = 80
    nginx['listen_https'] = false
    
    # Подключение к PostgreSQL (infra)
    gitlab_rails['db_adapter'] = 'postgresql'
    gitlab_rails['db_encoding'] = 'utf8'
    gitlab_rails['db_host'] = '${DB_HOST}'
    gitlab_rails['db_port'] = 5432
    gitlab_rails['db_username'] = '${DB_USER}'
    gitlab_rails['db_database'] = '${DB_NAME}'
    gitlab_rails['db_password'] = ENV['DB_PASSWORD']
    
    # Подключение к Redis (infra)
    gitlab_rails['redis_host'] = '${REDIS_HOST}'
    gitlab_rails['redis_port'] = 6379
    gitlab_rails['redis_password'] = ENV['REDIS_PASSWORD']
    
    # Настройка SMTP Яндекс
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

    # ОПТИМИЗАЦИЯ ДЛЯ K3S (Зажимаем аппетиты Ruby под домашнюю лабу)
    puma['worker_processes'] = 2
    puma['min_threads'] = 2
    puma['max_threads'] = 4
    sidekiq['max_concurrency'] = 10
    
    # Отключаем тяжелый встроенный мониторинг, раз у нас k3s
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
          # ИСПРАВЛЕНО: Снизили планку, чтобы k3s не зависал в ContainerCreating
          limits:
            memory: 3.5Gi
          requests:
            memory: 1.8Gi
        volumeMounts:
        - name: gitlab-config-volume
          mountPath: /etc/gitlab/gitlab.rb
          subPath: gitlab.rb
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
echo "[SUCCESS] Манифесты применены. Оптимизированный GitLab CE отправлен на запуск!"