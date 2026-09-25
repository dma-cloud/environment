#!/usr/bin/env bash

# Скрипт для автоматической установки Docker на Debian (запуск от root)
set -e

echo "=== 1. Обновление пакетов и установка зависимостей ==="
apt-get update
apt-get install -y ca-certificates curl gnupg

# Add Docker's official GPG key:
apt update
apt install ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt update
apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "=== 5. Настройка прав пользователя ==="
# Если скрипт вызван через 'sudo', переменная $SUDO_USER содержит имя обычного юзера.
# Если запуск идет под чистым root, добавляем в группу его, либо вашего основного пользователя (замените dma на вашего, если нужно).
TARGET_USER=${SUDO_USER:-$USER}
if [ "$TARGET_USER" != "root" ]; then
    usermod -aG docker "$TARGET_USER"
    echo "Пользователь $TARGET_USER добавлен в группу docker."
fi

echo "========================================================="
echo " Docker успешно установлен"
echo "========================================================="
