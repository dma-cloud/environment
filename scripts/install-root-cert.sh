#!/bin/bash
set -e

GREEN='\033[0;32m' && YELLOW='\033[1;33m' && RED='\033[0;31m' && NC='\033[0m'

echo -e "${GREEN}=========================================================="
echo "    Модуль: Добавление корневого SSL-сертификата в ОС     "
echo -e "==========================================================${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ Ошибка: Запустите скрипт под root (su - или sudo bash)!${NC}"
    exit 1
fi

# Подтягиваем глобальные переменные из вашего setup.sh (или дефолты)
GITHUB_USER=${GITHUB_USER:-"dma-cloud"}
GITHUB_REPO=${GITHUB_REPO:-"environment"}
BRANCH=${BRANCH:-"master"}

# Имя файла вашего сертификата в Git (поправьте, если называется иначе)
read -p "Введите имя файла корневого сертификата [дефолт: root.lab.crt]: " INPUT_CERT_NAME
CERT_NAME=${INPUT_CERT_NAME:-"root.lab.crt"}

URL_CERT="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/refs/heads/${BRANCH}/certs/${CERT_NAME}"

# Путь к системному хранилищу доверенных сертов (универсальный для Debian/Ubuntu)
CERT_DEST_DIR="/usr/local/share/ca-certificates"
FINAL_CERT_PATH="${CERT_DEST_DIR}/${CERT_NAME}"

echo "=== Загрузка публичного SSL-сертификата из GitOps... ==="
mkdir -p "$CERT_DEST_DIR"

if curl -s -f -L "$URL_CERT" -o "$FINAL_CERT_PATH"; then
    echo -e "${GREEN}Сертификат успешно скачан и сохранен в: $FINAL_CERT_PATH${NC}"
else
    echo -e "${RED}❌ Ошибка: Не удалось скачать $CERT_NAME из Git!${NC}"
    echo "Проверьте, что файл лежит в репозитории по пути: certs/$CERT_NAME"
    exit 1
fi

echo ""
echo "=== Обновление системного хранилища доверенных сертификатов ==="
# Нативная команда Debian/Ubuntu для пересчета доверенных сертов
if update-ca-certificates; then
    echo -e "${GREEN}🎉 Корневой сертификат успешно добавлен в систему!${NC}"
    echo "Теперь все локальные утилиты (curl, wget) и поды K3s будут доверять доменам .lab"
else
    echo -e "${RED}❌ Ошибка при выполнении update-ca-certificates.${NC}"
    exit 1
fi
