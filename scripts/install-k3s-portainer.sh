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

if ! command -v base64 &> /dev/null; then
    echo "[ERROR] Утилита base64 не найдена."
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

# 4. Проверка и синхронизация TLS Wildcard-сертификата
echo "[INFO] Синхронизация SSL-сертификатов кластера..."
if kubectl get secret wildcard-lab-tls -n portainer &>/dev/null; then
    echo "[INFO] Секрет 'wildcard-lab-tls' уже существует. Шаг пропущен."
else
    if kubectl get secret wildcard-lab-tls -n infra &>/dev/null; then
        kubectl create secret tls wildcard-lab-tls \
            --namespace=portainer \
            --cert=<(kubectl get secret wildcard-lab-tls -n infra -o jsonpath='{.data.['\''tls.crt'\'']}' | base64 --decode) \
            --key=<(kubectl get secret wildcard-lab-tls -n infra -o jsonpath='{.data.['\''tls.key'\'']}' | base64 --decode) \
            --dry-run=client -o yaml | kubectl apply -f -
        echo "[INFO] TLS-секрет успешно скопирован в пространство 'portainer'."
    else
        echo "[ERROR] Секрет 'wildcard-lab-tls' не найден в пространстве 'infra'."
        exit 1
    fi
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
        # Официальный кэшируемый образ с Docker Hub
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
  storageClassName: local-path  # Нарезаем место на LVM мастера
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi             # 10 ГБ под внутренние данные панели с избытком
---
apiVersion: v1
kind: Service
metadata:
  name: portainer-service
  namespace: portainer
spec:
  ports:
  - port: 9000
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
              number: 9000
  tls:
  - hosts:
    - $PORTAINER_DOMAIN
    secretName: wildcard-lab-tls  # Полноценный HTTPS через ваш wildcard
---
# Авторизационные права: создаем ServiceAccount и связываем с админом кластера
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
echo "При первом входе система предложит вам задать пароль администратора."