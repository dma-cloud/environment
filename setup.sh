#!/bin/bash
set -e

# Проверка на root-права
if [ "$EUID" -ne 0 ]; then
    echo "❌ Ошибка: Запустите скрипт под root (su - или sudo bash)!"
    exit 1
fi

echo "=========================================================="
echo "    Конфигурация источника GitOps (GitHub)               "
echo "=========================================================="

# 1. Запрашиваем параметры с умными дефолтами
read -p "Введите GitHub User/Org [дефолт: dma-cloud]: " INPUT_USER
GITHUB_USER=${INPUT_USER:-"dma-cloud"}

read -p "Введите GitHub Repository [дефолт: environment]: " INPUT_REPO
GITHUB_REPO=${INPUT_REPO:-"environment"}

read -p "Введите ветку GitHub (Branch) [дефолт: master]: " INPUT_BRANCH
BRANCH=${INPUT_BRANCH:-"master"}

# Формируем базовый URL для скачивания модулей динамически
BASE_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/refs/heads/${BRANCH}/scripts"

echo "----------------------------------------------------------"
echo "Источник: https://github.com/${GITHUB_USER}/${GITHUB_REPO}/tree/${BRANCH}"
echo "Загрузка модулей из папки /scripts..."
echo "----------------------------------------------------------"
sleep 1 # Пауза для чтения информации

# Цвета для TUI
GREEN='\033[0;32m' && YELLOW='\033[1;33m' && RED='\033[0;31m' && NC='\033[0m'

# ==============================================================================
# УНИВЕРСАЛЬНАЯ ФУНКЦИЯ ДВИЖКА ЧЕКБОКСОВ (TUI MENU ENGINE)
# ==============================================================================
run_tui_menu() {
    local -n mods=$1
    local num_mods=$((${#mods[@]} / 2))
    local choices=()
    local cursor=0
    
    # Заполняем массив состояний нулями
    for ((i=0; i<num_mods; i++)); do choices+=(0); done

    while true; do
        clear >&2
        echo -e "${GREEN}==========================================================" >&2
        echo "    DMA-CLOUD: Модульный установщик инфраструктуры        " >&2
        echo -e "==========================================================${NC}" >&2
        echo " Навигация: [Стрелки Вверх/Вниз]  Выбор: [Пробел]  Подтвердить: [Enter]" >&2
        echo "----------------------------------------------------------" >&2
        
        for ((i=0; i<num_mods; i++)); do
            local marker="[ ]"
            if [ "${choices[i]}" -eq 1 ]; then marker="[*]"; fi
            if [ "$i" -eq "$cursor" ]; then
                echo -e "> \033[1;32m$marker ${mods[i*2+1]}\033[0m" >&2
            else
                echo "  $marker ${mods[i*2+1]}" >&2
            fi
        done
        echo "----------------------------------------------------------" >&2

        # Считываем нажатие клавиши
        IFS= read -rsn1 key < /dev/tty
        
        # Обработка управляющих escape-последовательностей (Стрелки)
        if [[ "$key" == $'\x1b' ]]; then
            IFS= read -rsn2 -t 0.1 key_arrows < /dev/tty || true
            if [[ "$key_arrows" == "[A" ]]; then # Вверх
                cursor=$((cursor - 1))
                if [ "$cursor" -lt 0 ]; then cursor=$((num_mods - 1)); fi
            elif [[ "$key_arrows" == "[B" ]]; then # Вниз
                cursor=$((cursor + 1))
                if [ "$cursor" -ge "$num_mods" ]; then cursor=0; fi
            fi
        elif [[ "$key" == "" ]]; then # Клавиша Enter
            break
        elif [[ "$key" == " " ]]; then # Клавиша Пробел
            # ИСПРАВЛЕНО: Инвертируем состояние строго для выбранного индекса cursor
            if [ "${choices[cursor]}" -eq 1 ]; then
                choices[cursor]=0
            else
                choices[cursor]=1
            fi
        fi
    done

    # Возвращаем строку индексов выбранных элементов
    for ((i=0; i<num_mods; i++)); do
        if [ "${choices[i]}" -eq 1 ]; then echo -n "$i "; fi
    done
}
# ==============================================================================

# Доступные модули (Имя файла в Git -> Описание в интерфейсе)
MODULES=(
    "install-dns.sh"   "Инициализация DNS-сервера (dnsmasq + SOPS) на VPS"
    "install-wg.sh"    "Настройка WireGuard туннеля (Split Tunneling + MTU)"
    "enable-swap.sh"   "Создание SWAP-файла на SSD (для слабых серверов)"
    "update-a-records.sh"  "Ленивое обновление физической карты сети (A-записи)"
    "install-root-cert.sh" "Добавление корневого SSL-сертификата в доверенные ОС"
)

# Запускаем движок
SELECTED_INDEXES=$(run_tui_menu MODULES)

if [ -z "$SELECTED_INDEXES" ]; then
    echo "Ни один компонент не выбран. Выход."
    exit 0
fi

clear
echo -e "${YELLOW}=== Начинаем поочередную установку выбранных модулей ===${NC}\n"

# Скачиваем и выполняем выбранные скрипты последовательно
for idx in $SELECTED_INDEXES; do
    SCRIPT_NAME="${MODULES[idx*2]}"
    SCRIPT_DESC="${MODULES[idx*2+1]}"
    
    echo -e "\033[1;33m>> Запуск модуля: $SCRIPT_DESC... \033[0m"
    echo "----------------------------------------------------------"
    
    TMP_SCRIPT=$(mktemp)
    if curl -s -f -L "${BASE_URL}/${SCRIPT_NAME}" -o "$TMP_SCRIPT"; then
        chmod +x "$TMP_SCRIPT"
        # Направляем tty внутрь подскрипта, чтобы интерактивные read работали корректно
        if ! "$TMP_SCRIPT" </dev/tty; then
            echo -e "${RED}❌ Ошибка при выполнении модуля $SCRIPT_NAME. Остановка.${NC}"
            rm -f "$TMP_SCRIPT"
            exit 1
        fi
        rm -f "$TMP_SCRIPT"
    else
        echo -e "${RED}❌ Ошибка: Не удалось скачать скрипт ${SCRIPT_NAME} из Git!${NC}"
        echo "Проверьте путь: ${BASE_URL}/${SCRIPT_NAME}"
        rm -f "$TMP_SCRIPT"
        exit 1
    fi
done

echo -e "\n${GREEN}🎉 Все выбранные компоненты успешно установлены!${NC}"
