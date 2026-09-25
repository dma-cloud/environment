#!/bin/bash

# Скрипт для интерактивной настройки инфраструктуры (PostgreSQL 17 + Redis + pgAdmin 4) в k3s
# Разработано в рамках инфраструктуры dma-cloud/environment

set -e

echo "====================================================="
echo "   Настройка инфраструктурного стека (k3s: infra)    "
echo "====================================================="

# 1. Проверяем наличие kubectl
if ! command -v kubectl &> /dev/null; then
    echo "[ERROR] Утилита kubectl не найдена. Сначала установите k3s-master!"
    exit 1
fi

# Функция для получения или генерации пароля
get_or_gen_password() {
    local prompt_text="$1"
    local user_input
    local generated_pass

    echo "$prompt_text"
    echo "1) Сгенерировать надежный случайный пароль автоматически"
    echo "2) Ввести пароль вручную"
    echo -n "Выберите вариант (1 или 2): "
    read -r choice

    if [ "$choice" = "1" ]; then
        generated_pass=$(openssl rand -base64 18)
        echo "[INFO] Сгенерирован пароль: $generated_pass"
        echo "$generated_pass"
    elif [ "$choice" = "2" ]; then
        echo -n "Введите пароль (символы скрыты): "
        read -s user_input
        echo ""
        if [ -z "$user_input" ]; then
            echo "[ERROR] Пароль не может быть пустым!" >&2
            exit 1
        fi
        echo "$user_input"
    else
        echo "[ERROR] Неверный выбор!" >&2
        exit 1
    fi
}

# 2. Интерактивный опрос пользователя (Без дефолтных значений)
echo "[Настройка учетных данных pgAdmin 4]"
echo -n "Введите Email администратора для входа в pgAdmin: "
read -r PGADMIN_EMAIL
if [ -z "$PGADMIN_EMAIL" ]; then
    echo "[ERROR] Email не может быть пустым!"
    exit 1
fi

echo -n "Введите доменное имя для pgAdmin (например, pgadmin.lab): "
read -r PGADMIN_DOMAIN
if [ -z "$PGADMIN_DOMAIN" ]; then
    echo "[ERROR] Доменное имя не может быть пустым!"
    exit 1
fi

echo ""
echo "[Инфраструктура PostgreSQL 17]"
POSTGRES_PASS=$(get_or_gen_password "Каким образом задать главный пароль для СУБД (суперпользователь)?")

echo ""
echo "[База данных GitLab]"
GITLAB_DB_PASS=$(get_or_gen_password "Каким образом задать пароль для базы данных GitLab?")

echo ""
echo "[Администратор GitLab]"
GITLAB_ROOT_PASS=$(get_or_gen_password "Каким образом задать пароль root для веб-интерфейса GitLab?")

echo ""
echo "[Панель управления pgAdmin 4]"
PGADMIN_PASS=$(get_or_gen_password "Каким образом задать пароль для входа в pgAdmin?")

# 3. Создаем Namespace
echo ""
echo "[INFO] Проверка и создание пространства имен 'infra'..."
kubectl create namespace infra --dry-run=client -o yaml | kubectl apply -f -

# 4. Создаем секреты напрямую в кластере
echo "[INFO] Создание безопасных секретов в Kubernetes..."
kubectl create secret generic postgres-infra-secrets \
  --namespace=infra \
  --from-literal=postgres-password="$POSTGRES_PASS" \
  --from-literal=gitlab-db-password="$GITLAB_DB_PASS" \
  --from-literal=gitlab-root-password="$GITLAB_ROOT_PASS" \
  --from-literal=pgadmin-password="$PGADMIN_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -

# 5. Применяем манифест инфраструктуры (Переменные подставляются на лету)
echo "[INFO] Развертывание полного стека (SATA LVM / local-path)..."

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-infra
  namespace: infra
  labels:
    app: redis-infra
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis-infra
  template:
    metadata:
      labels:
        app: redis-infra
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379
          name: redis
        resources:
          limits:
            memory: 512Mi
          requests:
            memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: redis-infra-service
  namespace: infra
spec:
  ports:
  - port: 6379
    targetPort: 6379
  selector:
    app: redis-infra
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres-infra
  namespace: infra
  labels:
    app: postgres-infra
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres-infra
  template:
    metadata:
      labels:
        app: postgres-infra
    spec:
      containers:
      - name: postgres
        image: postgres:17-alpine
        ports:
        - containerPort: 5432
          name: postgres
        env:
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgres-infra-secrets
              key: postgres-password
        resources:
          limits:
            memory: 2Gi
          requests:
            memory: 1Gi
        volumeMounts:
        - mountPath: /var/lib/postgresql/data
          name: pg-data
      volumes:
      - name: pg-data
        persistentVolumeClaim:
          claimName: postgres-infra-pvc
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-infra-pvc
  namespace: infra
spec:
  storageClassName: local-path
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 30Gi
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-infra-service
  namespace: infra
spec:
  ports:
  - port: 5432
    targetPort: 5432
  selector:
    app: postgres-infra
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pgadmin-infra
  namespace: infra
  labels:
    app: pgadmin-infra
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pgadmin-infra
  template:
    metadata:
      labels:
        app: pgadmin-infra
    spec:
      containers:
      - name: pgadmin
        image: dpage/pgadmin4:latest
        ports:
        - containerPort: 80
          name: http
        env:
        - name: PGADMIN_DEFAULT_EMAIL
          value: "$PGADMIN_EMAIL"
        - name: PGADMIN_DEFAULT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgres-infra-secrets
              key: pgadmin-password
        resources:
          limits:
            memory: 512Mi
          requests:
            memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: pgadmin-infra-service
  namespace: infra
spec:
  ports:
  - port: 80
    targetPort: 80
  selector:
    app: pgadmin-infra
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: pgadmin-ingress
  namespace: infra
spec:
  rules:
  - host: $PGADMIN_DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: pgadmin-infra-service
            port:
              number: 80
EOF

echo ""
echo "[SUCCESS] Полный стек (PostgreSQL 17 + Redis + pgAdmin 4) развернут!"
echo "После запуска подов веб-интерфейс будет доступен по адресу: https://$PGADMIN_DOMAIN"
echo "Логин: $PGADMIN_EMAIL"