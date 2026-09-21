#!/bin/bash
set -e

# Цвета для красивого вывода
GREEN='\033[0;32m' && YELLOW='\033[1;33m' && RED='\033[0;31m' && NC='\033[0m'

echo -e "${GREEN}=================================================="
echo "    Модуль: Создание SWAP-файла на SSD             "
echo -e "==================================================${NC}"
echo ""

# Проверяем root-права (на случай, если запущен отдельно)
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ Ошибка: Запустите скрипт под root!${NC}"
    exit 1
fi

SWAP_PATH="/swapfile"

# 1. Запрашиваем размер свопа с подстановкой 16 ГБ по умолчанию
read -p "Введите желаемый размер SWAP в гигабайтах [дефолт: 16]: " SWAP_SIZE_GB
SWAP_SIZE_GB=${SWAP_SIZE_GB:-16}

# Проверка на корректность ввода числового значения
if [[ ! "$SWAP_SIZE_GB" =~ ^[0-9]+$ ]] || [ "$SWAP_SIZE_GB" -le 0 ]; then
    echo -e "${RED}❌ Ошибка: Введите корректное целое число больше нуля!${NC}"
    exit 1
fi

# 2. Если старый своп уже существует — корректно его отключаем и удаляем
if [ -f "$SWAP_PATH" ]; then
    echo -e "${YELLOW}Предупреждение: Обнаружен старый файл подкачки. Отключение...${NC}"
    swapoff $SWAP_PATH || true
    rm -f $SWAP_PATH
fi

echo -e "${YELLOW}=== Выделение ${SWAP_SIZE_GB} ГБ на вашем SSD... ===${NC}"
# fallocate резервирует место на SSD мгновенно
fallocate -l "${SWAP_SIZE_GB}G" $SWAP_PATH

echo "=== Настройка прав безопасности ==="
# Закрываем доступ всем, кроме root, чтобы защитить данные из ОЗУ
chmod 600 $SWAP_PATH

echo "=== Форматирование файла в файловую систему SWAP ==="
mkswap $SWAP_PATH

echo "=== Активация SWAP-пространства в операционной системе ==="
swapon $SWAP_PATH

# 3. Добавление записи в fstab для сохранения автозапуска после перезагрузки
if ! grep -q "$SWAP_PATH" /etc/fstab; then
    echo "=== Добавление записи в автозагрузку (/etc/fstab) ==="
    echo "$SWAP_PATH none swap sw 0 0" | tee -a /etc/fstab
fi

# 4. Тюнинг ядра Linux 
# Значение 10 заставляет ядро использовать физическую ОЗУ до последнего мегабайта
# и обращаться к SSD только при реальном дефиците памяти.
echo "=== Оптимизация параметров ядра (vm.swappiness=10) ==="
if grep -q "vm.swappiness" /etc/sysctl.conf; then
    sed -i 's/vm.swappiness.*/vm.swappiness=10/' /etc/sysctl.conf
else
    echo "vm.swappiness=10" | tee -a /etc/sysctl.conf
fi
sysctl -p

echo ""
echo -e "${GREEN}🎉 SWAP-файл на ${SWAP_SIZE_GB} ГБ успешно создан и активирован!${NC}"
echo "----------------------------------------------------------"
echo "Текущий статус оперативной памяти и подкачки (free -h):"
free -h
echo "----------------------------------------------------------"
