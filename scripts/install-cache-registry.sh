#!/bin/bash

# Скрипт для развертывания локальных регистров и прокси-кэшей артефактов
# Разработано в рамках инфраструктуры dma-cloud/environment

set -e

echo "====================================================="
echo "   Установка локальных кэшей и Docker Registry       "
echo "====================================================="

# 1. Проверяем наличие docker и docker compose
if ! command -v docker &> /dev/null; then
    echo "[ERROR] Docker не установлен на этом сервере!"
    exit 1
fi

# 2. Создаем структуру директорий на накопителе под кэши
echo "[INFO] Создание папок для хранения данных на /mnt/registry/..."
 mkdir -p /mnt/registry/verdaccio/storage
 mkdir -p /mnt/registry/verdaccio/plugins
 mkdir -p /mnt/registry/docker-registry
 mkdir -p /mnt/registry/go-registry

# Выставляем права, чтобы контейнеры могли писать на диск
 chmod -R 777 /mnt/registry/

# 3. Разворачиваем Docker Compose стек напрямую (минуя создание файлов на диске)
echo "[INFO] Запуск контейнеров кэширования с лимитами памяти..."

# Переходим в /opt для стандартизации размещения
 mkdir -p /opt/registry-cache
cd /opt/registry-cache

 tee docker-compose.yml > /dev/null <<EOF
version: '3.8'

services:
  # 1. NPM Кэш + Регистр (Слушает порт 4873)
  npm-registry:
    image: verdaccio/verdaccio:5
    container_name: verdaccio-npm
    user: "root"
    ports:
      - "4873:4873"
    volumes:
      - /mnt/registry/verdaccio/storage:/verdaccio/storage
      - /mnt/registry/verdaccio/plugins:/verdaccio/plugins
    restart: always
    deploy:
      resources:
        limits:
          memory: 512M
        reservations:
          memory: 256M

  # 2. Docker Registry v2 (Слушает порт 5000)
  docker-registry:
    image: registry:2
    container_name: local-docker-registry
    ports:
      - "5000:5000"
    environment:
      REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY: /var/lib/registry
    volumes:
      - /mnt/registry/docker-registry:/var/lib/registry
    restart: always
    deploy:
      resources:
        limits:
          memory: 384M
        reservations:
          memory: 128M

  # 3. Go Proxy Athens (Слушает порт 3000)
  go-registry:
    image: gomods/athens:v0.13.0
    container_name: athens-go
    ports:
      - "3000:3000"
    environment:
      - ATHENS_STORAGE_TYPE=disk
      - ATHENS_DISK_STORAGE_ROOT=/var/lib/athens
    volumes:
      - /mnt/registry/go-registry:/var/lib/athens
    restart: always
    deploy:
      resources:
        limits:
          memory: 384M
        reservations:
          memory: 128M
EOF

# Запуск стека
 docker compose up -d

echo ""
echo "[SUCCESS] Кэш-сервер успешно запущен!"
echo "NPM Registry (Verdaccio) доступен на порту: 4873"
echo "Docker Registry доступен на порту: 5000"
echo "Go Proxy (Athens) доступен на порту: 3000"