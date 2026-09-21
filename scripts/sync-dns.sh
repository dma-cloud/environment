#!/bin/bash
set -e

# Конфигурация репозитория
GITHUB_USER="dma-cloud"
GITHUB_REPO="environment"
BRANCH="master"

# Пути к файлам на сервере
FINAL_CNAME="/etc/dnsmasq.d/cname.conf"
CACHE_SHA_FILE="/opt/dns-sync/last_commit.sha"

# 1. Запрашиваем только SHA последнего коммита через GitHub API (легковесный запрос)
# GitHub API отдает JSON, откуда мы вырезаем чистый хэш коммита
ONLINE_SHA=$(curl -s -f "https://api.github.com/repos/${GITHUB_USER}/${GITHUB_REPO}/commits/${BRANCH}" | grep '"sha":' | head -n 1 | awk -F'"' '{print $4}' || true)

if [ -z "$ONLINE_SHA" ]; then
    echo "⚠️ [GitOps] Не удалось получить статус репозитория от GitHub API. Пропуск итерации."
    exit 0
fi

# 2. Читаем локально сохраненный хэш предыдущей успешной синхронизации
LOCAL_SHA=""
if [ -f "$CACHE_SHA_FILE" ]; then
    LOCAL_SHA=$(cat "$CACHE_SHA_FILE")
fi

# 3. Сравниваем внешний признак (SHA коммита)
if [ "$ONLINE_SHA" == "$LOCAL_SHA" ] && [ -f "$FINAL_CNAME" ]; then
    # Хэши совпали — изменений в репозитории гарантированно нет! В файл не лезем.
    exit 0
fi

echo "=== [GitOps] Обнаружен новый коммит в Git ($ONLINE_SHA). Начинаем обновление... ==="

# 4. Только теперь скачиваем файл cname.map целиком, раз коммит обновился
URL_CNAME="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/refs/heads/${BRANCH}/dns-config/cname.map"
TMP_CNAME=$(mktemp)

if curl -s -f -L "$URL_CNAME" -o "$TMP_CNAME"; then
    # Копируем файл на место системного
    cp "$TMP_CNAME" "$FINAL_CNAME"
    chmod 644 "$FINAL_CNAME"
    rm -f "$TMP_CNAME"
    
    # Сохраняем новый хэш в локальный кэш, чтобы при следующем запуске не качать файл заново
    echo "$ONLINE_SHA" > "$CACHE_SHA_FILE"
    
    # Мягко отправляем SIGHUP dnsmasq для перечитывания CNAME в памяти на лету
    if systemctl restart dnsmasq 2>/dev/null || service dnsmasq restart 2>/dev/null; then
        echo "🎉 Служба DNS успешно перезапущена. Все новые CNAME-алиасы активны!"
    else
        echo "⚠️ Ошибка: Не удалось перезапустить dnsmasq. Возможно, служба не установлена."
    fi
else
    echo "❌ Ошибка: Не удалось скачать cname.map, хотя коммит обновился."
    rm -f "$TMP_CNAME"
    exit 1
fi
