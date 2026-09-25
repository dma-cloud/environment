#!/bin/bash

# Скрипт для интерактивного создания TLS-секретов из буфера обмена (Ctrl+D)
# Разработано в рамках инфраструктуры dma-cloud/environment

set -e

echo "====================================================="
echo "   Импорт TLS Wildcard Сертификатов в k3s (*.lab)    "
echo "====================================================="

# 1. Проверяем наличие kubectl
if ! command -v kubectl &> /dev/null; then
    echo "[ERROR] Утилита kubectl не найдена. Сначала установите k3s-master!"
    exit 1
fi

# 2. Запрашиваем пространство имен (Namespace)
echo -n "Введите Namespace для SSL-секрета (по умолчанию: infra): "
read -r TARGET_NS
TARGET_NS=${TARGET_NS:-infra}

# Убеждаемся, что Namespace существует
kubectl create namespace "$TARGET_NS" --dry-run=client -o yaml | kubectl apply -f -

# 3. Интерактивный ввод Сертификата (Public CRT)
echo ""
echo "--- Шаг 1: Вставка Публичного Сертификата (Certificate / CRT) ---"
echo "Вставьте содержимое файла сертификата (включая BEGIN/END CERTIFICATE)"
echo "После окончания вставки нажмите Enter, а затем Ctrl+D:"
echo "-----------------------------------------------------------------"

CRT_CONTENT=$(cat)

if [ -z "$CRT_CONTENT" ]; then
    echo "[ERROR] Содержимое сертификата пустое! Операция отменена."
    exit 1
fi

# 4. Интерактивный ввод Приватного Ключа (Private KEY)
echo ""
echo "--- Шаг 2: Вставка Приватного Ключа (Private Key / KEY) ---"
echo "Вставьте содержимое приватного ключа (включая BEGIN/END PRIVATE KEY)"
echo "После окончания вставки нажмите Enter, а затем Ctrl+D:"
echo "-----------------------------------------------------------------"

KEY_CONTENT=$(cat)

if [ -z "$KEY_CONTENT" ]; then
    echo "[ERROR] Содержимое ключа пустое! Операция отменена."
    exit 1
fi

# 5. Создание TLS-секрета в кластере напрямую из переменных (минуя жесткий диск)
echo ""
echo "[INFO] Передача TLS-данных в API Kubernetes..."

# Передаем содержимое через bash-подстановку процессов (Process Substitution)
# Это позволяет утилите kubectl прочитать строки как физические файлы без их записи на диск
kubectl create secret tls wildcard-lab-tls \
  --namespace="$TARGET_NS" \
  --cert=<(echo "$CRT_CONTENT") \
  --key=<(echo "$KEY_CONTENT") \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "[SUCCESS] SSL-секрет 'wildcard-lab-tls' успешно создан в пространстве '$TARGET_NS'!"
echo "Вы можете проверить его наличие командой: kubectl get secrets -n $TARGET_NS"