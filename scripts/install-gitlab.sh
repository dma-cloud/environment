#!/bin/bash
# Модуль установки GitLab Community Edition (CE) в Namespace 'devops'
# ИСПОЛЬЗУЮТСЯ ТОЛЬКО ЧИСТЫЕ KUBERNETES MANIFESTS (БЕЗ HELM)

set -euo pipefail

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "====================================================="
echo "   Настройка GitLab CE через Кубернетис Манифесты    "
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

# 2. Проверка и создание Namespace
echo "[INFO] Проверка пространства имен '${NAMESPACE}'..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# 3. Синхронизация и генерация секретов
if kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" &> /dev/null; then
    echo "[INFO] Секрет '${SECRET_NAME}' уже существует. Пропускаем настройку."
    GITLAB_DOMAIN=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.gitlab-domain}' | base64 --decode)
else
    echo "[INFO] Секреты не найдены. Запускается импорт данных..."
    
    printf '%s' "Введите базовый домен для GitLab (например, gitlab.lab): "
    if ! IFS= read -r GITLAB_DOMAIN; then echo "[ERROR] Ошибка чтения."; exit 1; fi
    GITLAB_DOMAIN=${GITLAB_DOMAIN:-"gitlab.lab"}

    # Автоматически забираем учетные данные Яндекса и базы из существующей инфры
    if kubectl get secret "${INFRA_SECRET}" -n "${INFRA_NS}" &> /dev/null; then
        echo "[INFO] Пароли СУБД и Redis импортируются из пространства '${INFRA_NS}'..."
        
        DB_USER="gitlab"
        DB_NAME="gitlabhq_production"
        DB_PASS=$(kubectl get secret "${INFRA_SECRET}" -n "${INFRA_NS}" -o jsonpath='{.data.gitlab-db-password}')
        REDIS_PASS=$(kubectl get secret "${INFRA_SECRET}" -n "${INFRA_NS}" -o jsonpath='{.data.redis-password}')
        
        # Запрашиваем только почту Яндекса (так как в инфре её могло не быть)
        printf '%s' "Введите email Яндекс для SMTP (например, user@yandex.ru): "
        if ! IFS= read -r SMTP_USER; then echo "[ERROR] Ошибка чтения."; exit 1; fi
        
        printf '%s' "Введите пароль приложения Яндекс SMTP (символы скрыты): "
        if ! IFS= read -r -s SMTP_PASS; then echo "[ERROR] Ошибка чтения."; exit 1; fi
        printf '\n'
        
        # Кодируем новые данные в base64
        B64_SMTP_USER=$(echo -n "$SMTP_USER" | base64 | tr -d '\n')
        B64_SMTP_PASS=$(echo -n "$SMTP_PASS" | base64 | tr -d '\n')
        B64_DOMAIN=$(echo -n "$GITLAB_DOMAIN" | base64 | tr -d '\n')

        # Записываем объединенный секрет
        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
type: Opaque
data:
  smtp-username: ${B64_SMTP_USER}
  smtp-password: ${B64_SMTP_PASS}
  postgres-username: $(echo -n "$DB_USER" | base64 | tr -d '\n')
  postgres-password: ${DB_PASS}
  postgres-database: $(echo -n "$DB_NAME" | base64 | tr -d '\n')
  redis-password: ${REDIS_PASS}
  gitlab-domain: ${B64_DOMAIN}
EOF
    else
        echo "[ERROR] Секрет базы данных '${INFRA_SECRET}' в пространстве '${INFRA_NS}' не найден!"
        echo "Сначала разверните базовую инфраструктуру postgres/redis."
        exit 1
    fi
fi

# 4. Развертывание GitLab CE через чистый декларативный манифест
echo "[INFO] Применение манифестов GitLab CE в Kubernetes..."

kubectl apply -f - <<EOF
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
        # Связываем GitLab с твоим внешним PostgreSQL
        - name: GITLAB_OMNIBUS_CONFIG
          value: |
            external_url 'http://${GITLAB_DOMAIN}'
            
            # Отключение встроенных сервисов (Твое ключевое требование)
            postgresql['enable'] = false
            redis['enable'] = false
            nginx['listen_port'] = 80
            nginx['listen_https'] = false
            
            # Подключение к внешней Postgres в infra
            gitlab_rails['db_adapter'] = 'postgresql'
            gitlab_rails['db_encoding'] = 'utf8'
            gitlab_rails['db_host'] = 'postgres-infra-service.infra.svc.cluster.local'
            gitlab_rails['db_port'] = 5432
            
            # Подключение к внешнему Redis в infra
            gitlab_rails['redis_host'] = 'redis-infra-service.infra.svc.cluster.local'
            gitlab_rails['redis_port'] = 6379
            
            # Настройка SMTP Яндекс
            gitlab_rails['smtp_enable'] = true
            gitlab_rails['smtp_address'] = "smtp.yandex.ru"
            gitlab_rails['smtp_port'] = 465
            gitlab_rails['smtp_tls'] = true
            gitlab_rails['smtp_authentication'] = "login"
        
        # Передаем пароли в переменные среды из K8s секретов напрямую
        - name: DB_USER
          valueFrom:
            secretKeyRef:
              name: ${SECRET_NAME}
              key: postgres-username
        - name: DB_NAME
          valueFrom:
            secretKeyRef:
              name: ${SECRET_NAME}
              key: postgres-database
        - name: DB_PASS
          valueFrom:
            secretKeyRef:
              name: ${SECRET_NAME}
              key: postgres-password
        - name: REDIS_PASS
          valueFrom:
            secretKeyRef:
              name: ${SECRET_NAME}
              key: redis-password
        - name: SMTP_USER
          valueFrom:
            secretKeyRef:
              name: ${SECRET_NAME}
              key: smtp-username
        - name: SMTP_PASS
          valueFrom:
            secretKeyRef:
              name: ${SECRET_NAME}
              key: smtp-password
        resources:
          limits:
            memory: 4Gi
          requests:
            memory: 2Gi
        volumeMounts:
        - mountPath: /var/opt/gitlab
          name: gitlab-data
      volumes:
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
echo "[SUCCESS] GitLab CE успешно развернут из манифестов!"
echo "Мониторинг пода: kubectl get pods -n ${NAMESPACE} -w"