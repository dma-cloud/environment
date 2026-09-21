#!/bin/bash
set -e

echo "=========================================================="
echo "    Интерактивная настройка WireGuard на домашней ноде    "
echo "=========================================================="
echo ""

# Проверяем, запущен ли скрипт под root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Ошибка: Запустите скрипт под root (su - или sudo bash)!"
    exit 1
fi

# 1. Проверяем и устанавливаем WireGuard
if command -v wg &> /dev/null; then
    echo "=== [ПРОПУСК] WireGuard уже установлен в системе ==="
else
    echo "=== Установка WireGuard и системных утилит ==="
    apt-get update && apt-get install -y wireguard wireguard-tools
    echo "WireGuard успешно установлен."
fi

echo "----------------------------------------------------------"
echo "Шаг 1: Зайдите в админку wg-easy на вашей VPS."
echo "Шаг 2: Создайте профиль для этой ноды и откройте его конфиг (текст)."
echo "Шаг 3: Скопируйте весь текст конфигурации в буфер обмена."
echo "----------------------------------------------------------"
echo "Вставьте скопированный текст конфигурации ниже"
echo "и нажмите Ctrl+D, когда закончите ввод:"
echo "----------------------------------------------------------"

# 2. Перехватываем ввод конфига из буфера прямо во временный файл
TMP_CONF=$(mktemp)
cat > "$TMP_CONF"

# Проверяем, что пользователь вставил хоть что-то похожее на конфиг WireGuard
if ! grep -q "PrivateKey" "$TMP_CONF"; then
    echo "❌ Ошибка: Введенный текст не похож на легитимный конфиг WireGuard (нет строки PrivateKey)."
    rm -f "$TMP_CONF"
    exit 1
fi

echo "----------------------------------------------------------"
echo "=== Оптимизация конфигурации под 4G-модемы дата-центра ==="

# 3. Динамически определяем подсеть на основе Address в конфиге (например, 10.50.0.5/24 -> 10.50.0.0/24)
WG_SUBNET=$(grep -i "Address" "$TMP_CONF" | awk '{print $3}' | cut -d/ -f1 | cut -d. -f1-3).0/24

# Принудительно заменяем AllowedIPs на подсеть кластера (включаем Split Tunneling)
sed -i "s|AllowedIPs = .*|AllowedIPs = ${WG_SUBNET}|g" "$TMP_CONF"

# 4. Проверяем наличие параметра MTU, если его нет — дописываем в секцию [Interface]
if ! grep -q "MTU" "$TMP_CONF"; then
    # Добавляем MTU = 1360 сразу после адреса
    sed -i '/Address =.*/a MTU = 1360' "$TMP_CONF"
else
    sed -i 's|MTU = .*|MTU = 1360|g' "$TMP_CONF"
fi

# 5. Сохраняем готовый файл в систему
cp "$TMP_CONF" /etc/wireguard/wg0.conf
rm -f "$TMP_CONF"
chmod 600 /etc/wireguard/wg0.conf

echo "Файл /etc/wireguard/wg0.conf успешно сгенерирован и защищен."

# 6. Запуск сети и добавление в автозагрузку ОС
echo "=== Активация сетевого туннеля wg0 ==="
wg-quick down wg0 2>/dev/null || true
wg-quick up wg0
systemctl enable wg-quick@wg0

echo ""
echo "🎉 Сеть успешно настроена и запущена!"
echo "----------------------------------------------------------"
echo "Текущий статус интерфейса (wg show):"
wg show wg0 | grep -E "interface|endpoint|latest handshake" || true
echo "----------------------------------------------------------"

# 7. Динамическая диагностика сети на основе введенного конфига
# Вытаскиваем внешний IP/домен VPS из строки Endpoint (удаляя порт :51820)
SERVER_ENDPOINT=$(grep -i "Endpoint" /etc/wireguard/wg0.conf | awk '{print $3}' | cut -d: -f1)

# Вытаскиваем внутренний IP шлюза (берем первые 3 октета сети и подставляем .1)
INTERNAL_GW=$(grep -i "Address" /etc/wireguard/wg0.conf | awk '{print $3}' | cut -d. -f1-3).1

if [ -n "$SERVER_ENDPOINT" ]; then
    echo "1. Проверяем внешний интернет-канал до VPS ($SERVER_ENDPOINT):"
    ping -c 4 "$SERVER_ENDPOINT" || echo "⚠️ Внешний IP сервера недоступен. Проверьте интернет на модеме."
    echo "----------------------------------------------------------"
fi

echo "2. Проверяем доступность сетевого хаба внутри туннеля ($INTERNAL_GW):"
ping -c 4 "$INTERNAL_GW" || echo "⚠️ Пинг внутри VPN не прошел. Проверьте статус клиента в панели wg-easy."
echo "----------------------------------------------------------"
