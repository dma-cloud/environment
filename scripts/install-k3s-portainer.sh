#!/bin/bash

# Скрипт для интерактивного развертывания Portainer CE в k3s
# Разработано в рамках инфраструктуры dma-cloud/environment

set -euo pipefail

echo "====================================================="
echo "        Развертывание Portainer CE в кластере k3s    "
echo "====================================================="

# 1. Проверяем наличие необходимых утилит
if ! command -v kubectl &> /dev/null; then
    echo "[ERROR] Утилита kubectl не найдена. Сначала установите k3s-master!"
    exit 1
fi

# 2. Запрашиваем домен
printf '%s' "Введите доменное имя для Portainer (например, portainer.lab): "
if ! IFS= read -r PORTAINER_DOMAIN; then
    echo "[ERROR] Не удалось прочитать доменное имя."
    exit 1
fi
if [ -z "$PORTAINER_DOMAIN" ]; then
    echo "[ERROR] Домен не может быть пустым!"
    exit 1
fi

# 3. Создаем Namespace
echo "[INFO] Проверка и создание пространства имен 'portainer'..."
kubectl create namespace portainer --dry-run=client -o yaml | kubectl apply -f -

# 4. Интерактивный импорт TLS Wildcard-сертификата (через Ctrl+D)
echo "[INFO] Настройка SSL-сертификатов для пространства 'portainer'..."
if kubectl get secret wildcard-lab-tls -n portainer &>/dev/null; then
    echo "[INFO] Секрет 'wildcard-lab-tls' уже существует в пространстве 'portainer'. Шаг пропущен."
else
    echo ""
    echo "--- Шаг 4.1: Вставка Публичного Сертификата (Certificate / CRT) ---"
    echo "Вставьте содержимое файла сертификата (включая BEGIN/END CERTIFICATE)"
    echo "После окончания вставки нажмите Enter, а затем Ctrl+D:"
    echo "-----------------------------------------------------------------"
    
    # Читаем мультистрочный ввод из TTY
    CRT_CONTENT=$(cat)
    if [ -z "$CRT_CONTENT" ]; then
        echo "[ERROR] Содержимое сертификата пустое! Операция отменена."
        exit 1
    fi

    echo ""
    echo "--- Шаг 4.2: Вставка Приватного Ключа (Private Key / KEY) ---"
    echo "Вставьте содержимое приватного ключа (включая BEGIN/END PRIVATE KEY)"
    echo "После окончания вставки нажмите Enter, а затем Ctrl+D:"
    echo "-----------------------------------------------------------------"
    
    KEY_CONTENT=$(cat)
    if [ -z "$KEY_CONTENT" ]; then
        echo "[ERROR] Содержимое ключа пустое! Операция отменена."
        exit 1
    fi

    echo ""
    echo "[INFO] Передача TLS-данных в API Kubernetes..."
    
    # Чтобы kubectl гарантированно прочитал PEM-данные без Process Substitution,
    # мы создаем временные файлы в изолированной директории /tmp на мастере,
    # которая автоматически очищается, и сразу затираем их после создания секрета.
    TMP_DIR=$(mktemp -d)
    echo "$CRT_CONTENT" > "${TMP_DIR}/tls.crt"
    echo "$KEY_CONTENT" > "${TMP_DIR}/tls.key"

    kubectl create secret tls wildcard-lab-tls \
      --namespace=portainer \
      --cert="${TMP_DIR}/tls.crt" \
      --key="${TMP_DIR}/tls.key" \
      --dry-run=client -o yaml | kubectl apply -f -

    # Намертво вычищаем следы приватного ключа из папки /tmp
    rm -rf "$TMP_DIR"
    echo "[INFO] TLS-секрет успешно создан в пространстве 'portainer'."
fi

# 5. Применение манифестов Portainer CE (Официальный образ с Docker Hub)
echo "[INFO] Развертывание Portainer CE (SATA LVM / local-path)..."

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: portainer
  namespace: portainer
  labels:
    io.portainer.kubernetes: portainer
spec:
  replicas: 1
  selector:
    matchLabels:
      io.portainer.kubernetes: portainer
  template:
    metadata:
      labels:
        io.portainer.kubernetes: portainer
    spec:
      serviceAccountName: portainer-sa-admin
      containers:
      - name: portainer
        image: docker.io/portainer/portainer-ce:latest
        ports:
        - containerPort: 9000
          name: http
        - containerPort: 9443
          name: https
        resources:
          limits:
            memory: 512Mi
          requests:
            memory: 256Mi
        volumeMounts:
        - mountPath: /data
          name: portainer-data
      volumes:
      - name: portainer-data
        persistentVolumeClaim:
          claimName: portainer-pvc
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: portainer-pvc
  namespace: portainer
spec:
  storageClassName: local-path
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
apiVersion: v1
kind: Service
metadata:
  name: portainer-service
  namespace: portainer
spec:
  ports:
  - port: 80
    targetPort: 9000
    name: http
  selector:
    io.portainer.kubernetes: portainer
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: portainer-ingress
  namespace: portainer
spec:
  ingressClassName: traefik
  rules:
  - host: $PORTAINER_DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: portainer-service
            port:
              number: 80
  tls:
  - hosts:
    - $PORTAINER_DOMAIN
    secretName: wildcard-lab-tls
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: portainer-sa-admin
  namespace: portainer
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: portainer-crm
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: portainer-sa-admin
  namespace: portainer
EOF

echo ""
echo "[SUCCESS] Portainer CE успешно развернут!"
echo "Адрес веб-интерфейса: https://${PORTAINER_DOMAIN}"