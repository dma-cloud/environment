#!/bin/bash
set -e

GREEN='\033[0;32m' && YELLOW='\033[1;33m' && RED='\033[0;31m' && NC='\033[0m'

echo -e "${GREEN}=========================================================="
echo "    Модуль: Динамическая генерация и настройка DNS        "
echo -e "==========================================================${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ Ошибка: Запустите скрипт под root (su - или sudo bash)!${NC}"
    exit 1
fi

DNSMASQ_CONF="/etc/dnsmasq.conf"
FINAL_HOSTS="/etc/dnsmasq.hosts"

# 1. Автоматический сбор всех IPv4 адресов системы (кроме Docker/Loopback)
echo "=== Анализ сетевых интерфейсов... ==="
# Собираем реальные IP-адреса, исключая 127.0.0.1 и виртуальные интерфейсы docker/veth
IP_LIST=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | grep -v '^172\.' || true)

if [ -z "$IP_LIST" ]; then
    echo -e "${RED}❌ Ошибка: Не удалось обнаружить активные IPv4 адреса в системе!${NC}"
    exit 1
fi

# Формируем строку для listen-address (склеиваем через запятую с локальной петлей)
LISTEN_IPS="127.0.0.1"
echo "Найдены следующие IP-адреса:"
for ip in $IP_LIST; do
    echo " - $ip"
    LISTEN_IPS="${LISTEN_IPS},${ip}"
done

# 2. Интерактивный опрос доменной зоны
echo "--------------------------------------------------"
read -p "Введите имя доменной зоны лаборатории [дефолт: lab]: " INPUT_ZONE
DOMAIN_ZONE=${INPUT_ZONE:-"lab"}
# Очищаем от случайных точек в начале или конце, если пользователь ввел ".lab"
DOMAIN_ZONE=$(echo "$DOMAIN_ZONE" | sed 's/^\.//;s/\.$//')

# 3. Установка пакетов и SOPS, если их нет
if ! command -v dnsmasq &> /dev/null; then
    echo "=== Установка dnsmasq... ==="
    apt-get update && apt-get install -y dnsmasq curl
fi

if ! command -v sops &> /dev/null; then
    echo "=== Установка SOPS v3.13.3... ==="
    curl -LO https://github.com
    mv sops-v3.13.3.linux.amd64 /usr/local/bin/sops
    chmod +x /usr/local/bin/sops
fi

# 4. Генерация умного конфигурационного файла dnsmasq.conf
echo "=== Генерация умного конфигурационного файла $DNSMASQ_CONF ==="
cat <<EOF | tee "$DNSMASQ_CONF"
# ==============================================================================
#                 DMA-CLOUD: DYNAMIC DNSMASQ CONFIGURATION
# ==============================================================================

# 1. СЕТЕВЫЕ ИНТЕРФЕЙСЫ И АДРЕСА
# Автоматически сгенерировано на основе активных интерфейсов ноды
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
local Milch /${DOMAIN_ZONE}/
expand-hosts
domain=${DOMAIN_ZONE}

# 6. ИСТОЧНИКИ ДАННЫХ (ТАБЛИЦЫ АДРЕСОВ)
addn-hosts=${FINAL_HOSTS}
EOF

# 5. Создание пустышки файла хостов, если его еще нет (чтобы dnsmasq не ругался при старте)
if [ ! -f "$FINAL_HOSTS" ]; then
    echo "# Таблица адресов Homelab" > "$FINAL_HOSTS"
fi

# 6. Проверка конфигурации и перезапуск
echo "=== Тестирование конфигурации DNS... ==="
if dnsmasq --test; then
    echo -e "${GREEN}Синтаксис конфигурации DNS корректен.${NC}"
    
    # Решаем проблему занятого порта 53 со стороны systemd-resolved на Ubuntu/Debian
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        echo "Отключение системного резолвера systemd-resolved для освобождения порта 53..."
        systemctl stop systemd-resolved || true
        systemctl disable systemd-resolved || true
    fi
    
    systemctl restart dnsmasq
    systemctl enable dnsmasq
    echo -e "${GREEN}🎉 dnsmasq успешно настроен, перезапущен и слушает зону .${DOMAIN_ZONE}!${NC}"
else
    echo -e "${RED}❌ Ошибка: Тест конфигурации dnsmasq провалился!${NC}"
    exit 1
fi
