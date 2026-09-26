#!/bin/bash

# Скрипт для интерактивного развертывания Portainer CE в k3s
# Разработано в рамках infrastructure dma-cloud/environment

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

# 4. Проверка и синхронизация TLS Wildcard-сертификата (Нативный надежный экспорт)
echo "[INFO] Синхронизация SSL-сертификатов кластера..."
if kubectl get secret wildcard-lab-tls -n portainer &>/dev/null; then
    echo "[INFO] Секрет 'wildcard-lab-tls' уже существует. Шаг пропущен."
else
    if kubectl get secret wildcard-lab-tls -n infra &>/dev/null; then
        # ИСПРАВЛЕНО: Чистый перенос объекта через sed без разбора jsonpath и base64
        kubectl get secret wildcard-lab-tls -n infra -o yaml | \
            sed 's/namespace: infra/namespace: portainer/' | \
            kubectl apply -f -
        echo "[INFO] TLS-секрет успешно скопирован в пространство 'portainer'."
    else
        echo "[ERROR] Секрет 'wildcard-lab-tls' не найден в пространстве 'infra'."
        echo "[ERROR] Сначала импортируйте TLS-сертификат через install-k3s-certs.sh."
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