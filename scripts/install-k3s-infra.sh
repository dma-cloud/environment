#!/bin/bash

# Скрипт для настройки инфраструктуры (PostgreSQL 17 + Redis с паролем + pgAdmin 4) в k3s
# С автоматическим пропуском генерации секретов, если они уже существуют.

set -euo pipefail

echo "====================================================="
echo "   Настройка инфраструктурного стека (k3s: infra)    "
echo "====================================================="

# 1. Проверяем наличие утилит
if ! command -v kubectl &> /dev/null; then
    echo "[ERROR] Утилита kubectl не найдена. Сначала установите k3s-master!"
    exit 1
fi

if ! command -v openssl &> /dev/null; then
    echo "[ERROR] Утилита openssl не найдена. Установите OpenSSL для генерации паролей."
    exit 1
fi

# Функция для получения или генерации пароля
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
    if ! IFS= read -r choice; then
        echo "[ERROR] Не удалось прочитать выбор." >&2
        exit 1
    fi

    if [ "$choice" = "1" ]; then
        generated_pass=$(openssl rand -base64 18)
        printf '%s\n' "$generated_pass"
    elif [ "$choice" = "2" ]; then
        printf '%s' "Введите пароль (символы скрыты): " >&2
        if ! IFS= read -r -s user_input; then
            echo "[ERROR] Не удалось прочитать пароль." >&2
            exit 1
        fi
        printf '\n' >&2
        if [ -z "$user_input" ]; then
            echo "[ERROR] Пароль не может быть пустым!" >&2
            exit 1
        fi
        printf '%s\n' "$user_input"
    else
        echo "[ERROR] Неверный выбор!" >&2
        exit 1
    fi
}

# 2. Проверка и создание Namespace (нужно сделать до проверки секретов)
echo "[INFO] Проверка и создание пространства имен 'infra'..."
kubectl create namespace infra --dry-run=client -o yaml | kubectl apply -f -

# 3. Проверяем, существует ли уже секрет в кластере
SECRET_NAME="postgres-infra-secrets"
NAMESPACE="infra"

if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &> /dev/null; then
    echo "[INFO] Секрет '$SECRET_NAME' уже существует in namespace '$NAMESPACE'."
    echo "[INFO] Пропускаем интерактивный ввод данных. Будут использованы текущие секреты."
    
    if kubectl get ingress pgadmin-ingress -n "$NAMESPACE" &> /dev/null; then
        PGADMIN_DOMAIN=$(kubectl get ingress pgadmin-ingress -n "$NAMESPACE" -o jsonpath='{.spec.rules[0].host}')
        echo "[INFO] Домен для pgAdmin автоматически определен как: $PGADMIN_DOMAIN"
    else
        printf '%s' "Секреты найдены, но Ingress не настроен. Введите доменное имя для pgAdmin: "
        if ! IFS= read -r PGADMIN_DOMAIN; then echo "[ERROR] Ошибка чтения."; exit 1; fi
    fi
else
    echo "[INFO] Секреты не найдены. Запускается процесс интерактивной настройки..."
    echo ""
    
    # [Настройка учетных данных pgAdmin 4]
    printf '%s' "Введите Email администратора для входа в pgAdmin: "
    if ! IFS= read -r PGADMIN_EMAIL; then echo "[ERROR] Не удалось прочитать Email."; exit 1; fi
    if [ -z "$PGADMIN_EMAIL" ] || [[ ! "$PGADMIN_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        echo "[ERROR] Введите корректный Email."; exit 1;
    fi

    printf '%s' "Введите доменное имя для pgAdmin (например, pgadmin.lab): "
    if ! IFS= read -r PGADMIN_DOMAIN; then echo "[ERROR] Не удалось прочитать доменное имя."; exit 1; fi
    if [ -z "$PGADMIN_DOMAIN" ] || (( ${#PGADMIN_DOMAIN} > 253 )) ||
        [[ ! "$PGADMIN_DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]; then
        echo "[ERROR] Введите корректный доменное имя (DNS hostname)."; exit 1;
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

    # ИСПРАВЛЕНО: Добавлен интерактивный запрос пароля для Redis
    echo ""
    echo "[Инфраструктура Redis]"
    REDIS_PASS=$(get_or_gen_password "Каким образом задать защитный пароль для Redis?")

    # Создаем секреты напрямую в кластере, только если их не было
    echo ""
    echo "[INFO] Создание безопасных секретов в Kubernetes..."
    kubectl create secret generic "$SECRET_NAME" \
      --namespace="$NAMESPACE" \
      --from-literal="pgadmin-email=$PGADMIN_EMAIL" \
      --from-literal=postgres-password="$POSTGRES_PASS" \
      --from-literal=gitlab-db-password="$GITLAB_DB_PASS" \
      --from-literal=gitlab-root-password="$GITLAB_ROOT_PASS" \
      --from-literal=pgadmin-password="$PGADMIN_PASS" \
      --from-literal=redis-password="$REDIS_PASS" \
      --dry-run=client -o yaml | kubectl apply -f -
fi

# 4. Применяем манифест инфраструктуры (Переменные подставляются на лету)
echo ""
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
        # ИСПРАВЛЕНО: Передаем пароль через аргумент запуска Redis
        command: ["redis-server"]
        args: ["--requirepass", "\$(REDIS_PASSWORD)"]
        ports:
        - containerPort: 6379
          name: redis
        # ИСПРАВЛЕНО: Достаем защищенный пароль из Kubernetes Secret
        env:
        - name: REDIS_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgres-infra-secrets
              key: redis-password
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
          valueFrom:
            secretKeyRef:
              name: postgres-infra-secrets
              key: pgadmin-email
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
echo "[SUCCESS] Полный стек (PostgreSQL 17 + Защищенный Redis + pgAdmin 4) применен!"
echo "Адрес веб-интерфейса pgAdmin: http://$PGADMIN_DOMAIN"