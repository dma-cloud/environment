#!/bin/bash

# Скрипт для автоматической настройки прозрачного зеркалирования образов через кэш-сервер в k3s
# Разработано в рамках инфраструктуры dma-cloud/environment

set -e

echo "====================================================="
echo "   Настройка зеркалирования Docker Registry в k3s    "
echo "====================================================="

# 1. Интерактивный опрос параметров (без жестко зашитых значений)
echo -n "Введите доменное имя или IP вашего кэш-сервера (например, mirror.registry.lab): "
read -r CACHE_HOST
if [ -z "$CACHE_HOST" ]; then
    echo "[ERROR] Адрес кэш-сервера не может быть пустым!"
    exit 1
fi

echo -n "Введите порт локального Docker Registry (например, 5000): "
read -r CACHE_PORT
if [ -z "$CACHE_PORT" ]; then
    echo "[ERROR] Порт не может быть пустым!"
    exit 1
fi

# Уточняем протокол
echo "Какой протокол использует ваш Docker Registry?"
echo "1) HTTPS (безопасное соединение с вашим корневым CA)"
echo "2) HTTP (голый небезопасный протокол)"
echo -n "Выберите вариант (1 или 2): "
read -r PROTO_CHOICE

if [ "$PROTO_CHOICE" = "1" ]; then
    REGISTRY_URL="https://${CACHE_HOST}:${CACHE_PORT}"
    INSECURE_VAL="false"
elif [ "$PROTO_CHOICE" = "2" ]; then
    REGISTRY_URL="http://${CACHE_HOST}:${CACHE_PORT}"
    INSECURE_VAL="true"
else
    echo "[ERROR] Неверный выбор!"
    exit 1
fi

# 2. Создаем системную директорию для конфигурации k3s
echo "[INFO] Подготовка директорий..."
sudo mkdir -p /etc/rancher/k3s

# 3. Генерируем registries.yaml напрямую (минуя ручную правку файлов)
echo "[INFO] Запись системной конфигурации containerd..."

sudo tee /etc/rancher/k3s/registries.yaml > /dev/null <<EOF
mirrors:
  # Направляем все стандартные запросы к Docker Hub (docker.io) на ваш кэш
  "docker.io":
    endpoint:
      - "$REGISTRY_URL"
  # Также регистрируем сам локальный домен для явных вызовов
  "${CACHE_HOST}:${CACHE_PORT}":
    endpoint:
      - "$REGISTRY_URL"

configs:
  "${CACHE_HOST}:${CACHE_PORT}":
    tls:
      insecure_skip_verify: $INSECURE_VAL
EOF

# 4. Перезапускаем k3s службу для применения конфигурации
echo "[INFO] Перезапуск контейнерного движка для применения настроек..."
if systemctl is-active --quiet k3s; then
    sudo systemctl restart k3s
    echo "[SUCCESS] Мастер-нода k3s успешно перенаправлена на кэш-сервер!"
elif systemctl is-active --quiet k3s-agent; then
    sudo systemctl restart k3s-agent
    echo "[SUCCESS] Воркер-нода k3s успешно перенаправлена на кэш-сервер!"
else
    echo "[WARNING] Служба k3s/k3s-agent не запущена. Настройки применятся при следующем старте."
fi