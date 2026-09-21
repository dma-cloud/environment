#!/bin/bash
set -e

GREEN='\033[0;32m' && YELLOW='\033[1;33m' && RED='\033[0;31m' && NC='\033[0m'

echo -e "${GREEN}=========================================================="
echo "    Модуль: Настройка DNS-сервера (A-записи + CNAME GitOps) "
echo -e "==========================================================${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ Ошибка: Запустите скрипт под root (su - или sudo bash)!${NC}"
    exit 1
fi

# Пути к системным файлам dnsmasq
DNSMASQ_CONF="/etc/dnsmasq.conf"
FINAL_HOSTS="/etc/dnsmasq.hosts"
FINAL_CNAME="/etc/dnsmasq.cname"

# 1. Автоматический сбор всех IPv4 адресов системы
echo "=== Анализ сетевых интерфейсов... ==="
IP_LIST=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | grep -v '^172\.' || true)

if [ -z "$IP_LIST" ]; then
    echo -e "${RED}❌ Ошибка: Не удалось обнаружить активные IPv4 адреса!${NC}"
    exit 1
fi

LISTEN_IPS="127.0.0.1"
echo "Найдены активные интерфейсы:"
for ip in $IP_LIST; do
    echo " - $ip"
    LISTEN_IPS="${LISTEN_IPS},${ip}"
done

# 2. Интерактивный опрос параметров репозитория и доменной зоны
echo "----------------------------------------------------------"
read -p "Введите имя доменной зоны лаборатории [дефолт: lab]: " INPUT_ZONE
DOMAIN_ZONE=${INPUT_ZONE:-"lab"}
DOMAIN_ZONE=$(echo "$DOMAIN_ZONE" | sed 's/^\.//;s/\.$//')

# Спрашиваем параметры репозитория для скачивания CNAME (подставляем глобальные переменные загрузчика, если они экспортированы)
GITHUB_USER=${GITHUB_USER:-"dma-cloud"}
GITHUB_REPO=${GITHUB_REPO:-"environment"}
BRANCH=${BRANCH:-"master"}

# 3. Установка пакетов
if ! command -v dnsmasq &> /dev/null; then
    echo "=== Установка dnsmasq... ==="
    apt-get update && apt-get install -y dnsmasq curl
fi

# 4. ИНТЕРАКТИВНЫЙ ВВОД А-ЗАПИСЕЙ (Физическая карта сети)
echo ""
echo -e "${YELLOW}=== Настройка физической карты сети (A-записи) ===${NC}"
echo "Вставьте или введите локальные IP ваших серверов."
echo "Формат: IP_АДРЕС  ИМЯ_НОДЫ.${DOMAIN_ZONE}"
echo "----------------------------------------------------------"
echo -e "Пример ввода:\n192.168.2.2    master.${DOMAIN_ZONE}\n192.168.2.3    infra-atom.${DOMAIN_ZONE}"
echo "----------------------------------------------------------"
echo "Вносите данные ниже и нажмите Ctrl+D, когда закончите:"
echo "----------------------------------------------------------"

# Перехватываем ввод напрямую в системный файл хостов dnsmasq
cat > "$FINAL_HOSTS"

# Проверяем, что пользователь ввёл хоть какие-то записи
if [ ! -s "$FINAL_HOSTS" ]; then
    echo -e "${RED}❌ Ошибка: Список A-записей пуст! Настройка отменена.${NC}"
    exit 1
fi

# 5. СКАЧИВАНИЕ CNAME С GITHUB
echo ""
echo "=== Загрузка статических CNAME-записей из GitOps... ==="
URL_CNAME="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/refs/heads/${BRANCH}/dns-config/cname.map"

if curl -s -f -L "$URL_CNAME" -o "$FINAL_CNAME"; then
    echo -e "${GREEN}CNAME-алиасы успешно импортированы в $FINAL_CNAME${NC}"
else
    echo -e "${RED}❌ Ошибка: Не удалось скачать cname.map из Git! Проверьте путь в репозитории.${NC}"
    echo "Ссылка: $URL_CNAME"
    exit 1
fi

# 6. ГЕНЕРАЦИЯ МОНОЛИТНОГО DNSMASQ.CONF
echo "=== Конфигурация ядра dnsmasq... ==="
cat <<EOF | tee "$DNSMASQ_CONF"
# ==============================================================================
#                 DMA-CLOUD: HYBRID DNSMASQ CONFIGURATION
# ==============================================================================

# 1. СЕТЕВЫЕ ИНТЕРФЕЙСЫ И АДРЕСА
listen-address=${LISTEN_IPS}
bind-interfaces

# 2. БЕЗОПАСНОСТЬ И МАРШРУТИЗАЦИЯ ЗАПРОСОВ
domain-needed
bogus-priv
localise-queries

# 3. КЭШИРОВАНИЕ ТРАФИКА
cache-size=10000

# 4. ВНЕШНИЕ DNS-СЕРВЕРЫ (АПСТРИМЫ)
server=1.1.1.1
server=8.8.8.8

# 5. ЛОКАЛЬНАЯ ДОМЕННАЯ ЗОНА ЛАБОРАТОРИИ
local=/${DOMAIN_ZONE}/
expand-hosts
domain=${DOMAIN_ZONE}

# 6. ИСТОЧНИКИ ДАННЫХ (ДИНАМИЧЕСКИЕ A-ЗАПИСИ И СТАТИЧЕСКИЙ CNAME)
addn-hosts=${FINAL_HOSTS}
conf-file=${FINAL_CNAME}
EOF

# 7. ТЕСТИРОВАНИЕ И ПЕРЕЗАПУСК СЛУЖБЫ
echo "=== Проверка синтаксиса и запуск... ==="
if dnsmasq --test; then
    # Освобождаем порт 53, если он занят системным резолвером
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        systemctl stop systemd-resolved || true
        systemctl disable systemd-resolved || true
    fi
    
    systemctl restart dnsmasq
    systemctl enable dnsmasq
    echo -e "${GREEN}🎉 DNS-сервер успешно запущен! Зона .${DOMAIN_ZONE} обслуживается.${NC}"
else
    echo -e "${RED}❌ Ошибка: Конфигурация dnsmasq содержит критические ошибки!${NC}"
    exit 1
fi

# ==============================================================================
# 🚀 НОВЫЙ БЛОК: АВТОМАТИЧЕСКАЯ НАСТРОЙКА GITOPS CRON ДЛЯ CNAME
# ==============================================================================
echo ""
echo -e "${YELLOW}=== Настройка автоматической синхронизации CNAME (Cron) ===${NC}"

# 1. Создаем рабочую папку и скачиваем туда наш экономный синхронизатор
SYNC_DIR="/opt/dns-sync"
SYNC_SCRIPT="${SYNC_DIR}/sync-dns.sh"
mkdir -p "$SYNC_DIR"

URL_SYNC="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/refs/heads/${BRANCH}/scripts/sync-dns.sh"
echo "Скачивание крон-скрипта из Git..."

if curl -s -f -L "$URL_SYNC" -o "$SYNC_SCRIPT"; then
    chmod +x "$SYNC_SCRIPT"
    echo -e "${GREEN}Синхронизатор успешно сохранен в $SYNC_SCRIPT${NC}"
else
    echo -e "${RED}⚠️ Ошибка: Не удалось скачать sync-dns.sh из Git! Пропишите крон вручную.${NC}"
    exit 0 # Не валим весь инсталл из-за крона
fi

# 2. Безопасно добавляем задачу в crontab без дублирования строк
CRON_JOB="*/5 * * * * ${SYNC_SCRIPT} >> /var/log/dns-sync.log 2>&1"

# Проверяем, нет ли уже такой задачи в кроне у root
if crontab -l 2>/dev/null | grep -q "${SYNC_SCRIPT}"; then
    echo "✅ Задача автоматической синхронизации уже присутствует в crontab."
else
    # Берем текущий крон, дописываем новую строку и отдаем обратно планировщику
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    echo -e "${GREEN}🎉 Скрипт синхронизации успешно добавлен в crontab на каждые 5 минут!${NC}"
fi
echo "----------------------------------------------------------"
