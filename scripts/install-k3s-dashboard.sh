#!/bin/bash

# Скрипт для интерактивного развертывания стабильной версии Kubernetes Dashboard (v2.7.0)
# Разработано в рамках инфраструктуры dma-cloud/environment

set -e

echo "====================================================="
echo "      Развертывание Kubernetes Dashboard в k3s       "
echo "====================================================="

# 1. Проверяем наличие kubectl
if ! command -v kubectl &> /dev/null; then
    echo "[ERROR] Утилита kubectl не найдена. Сначала установите k3s-master!"
    exit 1
fi

# 2. Запрашиваем домен
echo -n "Введите доменное имя для панели управления (например, k3s.lab): "
read -r DASHBOARD_DOMAIN
if [ -z "$DASHBOARD_DOMAIN" ]; then
    echo "[ERROR] Домен не может быть пустым!"
    exit 1
fi

# 3. Создаем Namespace
echo "[INFO] Проверка и создание пространства имен 'kubernetes-dashboard'..."
kubectl create namespace kubernetes-dashboard --dry-run=client -o yaml | kubectl apply -f -

# 4. Проверка и синхронизация TLS Wildcard-сертификата
echo "[INFO] Синхронизация SSL-сертификатов кластера..."
if kubectl get secret wildcard-lab-tls -n kubernetes-dashboard &>/dev/null; then
    echo "[INFO] Секрет 'wildcard-lab-tls' уже существует в пространстве 'kubernetes-dashboard'. Шаг пропущен."
else
    if kubectl get secret wildcard-lab-tls -n infra &>/dev/null; then
        kubectl get secret wildcard-lab-tls -n infra -o yaml | sed 's/namespace: infra/namespace: kubernetes-dashboard/' | kubectl apply -f -
        echo "[INFO] TLS-секрет успешно скопирован в пространство 'kubernetes-dashboard'."
    else
        echo "[WARNING] Секрет 'wildcard-lab-tls' не найден в корневом пространстве 'infra'."
    fi
fi

# 5. Применение полных манифестов, RBAC и сервисных ключей безопасности
echo "[INFO] Применение манифестов, секретов шифрования сессий и RBAC..."

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  labels:
    k8s-app: kubernetes-dashboard
  name: kubernetes-dashboard-certs
  namespace: kubernetes-dashboard
type: Opaque
---
apiVersion: v1
kind: Secret
metadata:
  labels:
    k8s-app: kubernetes-dashboard
  name: kubernetes-dashboard-csrf
  namespace: kubernetes-dashboard
type: Opaque
data:
  # Пустая заглушка для инициализации токена сессии безопасности
  csrf: ""
---
apiVersion: v1
kind: Secret
metadata:
  labels:
    k8s-app: kubernetes-dashboard
  name: kubernetes-dashboard-key-holder
  namespace: kubernetes-dashboard
type: Opaque
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kubernetes-dashboard
  namespace: kubernetes-dashboard
  labels:
    k8s-app: kubernetes-dashboard
spec:
  replicas: 1
  selector:
    matchLabels:
      k8s-app: kubernetes-dashboard
  template:
    metadata:
      labels:
        k8s-app: kubernetes-dashboard
    spec:
      serviceAccountName: admin-user
      containers:
      - name: kubernetes-dashboard
        image: kubernetesui/dashboard:v2.7.0
        ports:
        - containerPort: 9090
          protocol: TCP
        args:
          - --namespace=kubernetes-dashboard
          - --http-port=9090
          # КРИТИЧНО ДЛЯ ВЕТКИ v2: принудительно заставляем панель слушать только голый HTTP внутри кластера
          - --enable-insecure-login=true
          - --sidecar-host=http://127.0.0.1:8000
        resources:
          limits:
            memory: 512Mi
          requests:
            memory: 256Mi
        volumeMounts:
        - mountPath: /certs
          name: kubernetes-dashboard-certs
        - mountPath: /tmp
          name: tmp-volume
      volumes:
      - name: kubernetes-dashboard-certs
        secret:
          secretName: kubernetes-dashboard-certs
      - name: tmp-volume
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: kubernetes-dashboard
  namespace: kubernetes-dashboard
  labels:
    k8s-app: kubernetes-dashboard
spec:
  ports:
  - port: 80
    targetPort: 9090
  selector:
    k8s-app: kubernetes-dashboard
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kubernetes-dashboard-ingress
  namespace: kubernetes-dashboard
spec:
  ingressClassName: traefik
  rules:
  - host: $DASHBOARD_DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: kubernetes-dashboard
            port:
              number: 80
  tls:
  - hosts:
    - $DASHBOARD_DOMAIN
    secretName: wildcard-lab-tls
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
EOF

echo ""
echo "[INFO] Генерация токена доступа для входа в панель..."
echo "-----------------------------------------------------------------"

DASH_TOKEN=$(kubectl -n kubernetes-dashboard create token admin-user --duration=8760h)

echo "ВАШ ТОКЕН ДЛЯ ВХОДА (Скопируйте его целиком):"
echo ""
echo "${DASH_TOKEN}"
echo "-----------------------------------------------------------------"
echo "[SUCCESS] Панель управления успешно развернута!"
echo "Адрес: https://${DASHBOARD_DOMAIN}"