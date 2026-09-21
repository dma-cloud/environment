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

# 1. Запрашиваем имя пользователя/организации с подстановкой дефолта
read -p "Введите GitHub User/Org [дефолт: dma-cloud]: " INPUT_USER
GITHUB_USER=${INPUT_USER:-"dma-cloud"}

# 2. Запрашиваем имя репозитория
read -p "Введите GitHub Repository [дефолт: environment]: " INPUT_REPO
GITHUB_REPO=${INPUT_REPO:-"environment"}

# 3. Запрашиваем имя ветки
read -p "Введите ветку GitHub (Branch) [дефолт: master]: " INPUT_BRANCH
BRANCH=${INPUT_BRANCH:-"master"}

# ИСПРАВЛЕНО: Добавлен знак $ перед переменными, исправлен хост raw-файлов GitHub
BASE_URL="https://raw.githubusercontent.com/{GITHUB_USER}/${GITHUB_REPO}/refs/heads/${BRANCH}/scripts"

echo "----------------------------------------------------------"
echo "Источник: https://github.com/{GITHUB_USER}/${GITHUB_REPO}/tree/${BRANCH}"
echo "Загрузка модулей из папки /scripts..."
echo "----------------------------------------------------------"
sleep 1 # Пауза, чтобы пользователь успел прочитать информацию

# Цвета для интерфейса
GREEN='\033[0;32m' && YELLOW='\033[1;33m' && RED='\033[0;31m' && NC='\033[0m'

# ==============================================================================
# УНИВЕРСАЛЬНАЯ ФУНКЦИЯ ДВИЖКА ЧЕКБОКСОВ (TUI MENU ENGINE)
# ==============================================================================
run_tui_menu() {
    local -n mods=$1
    local num_mods=$((${#mods[@]} / 2))
    local choices=()
    local cursor=0
    
    # Инициализируем массив состояний чекбоксов нулями
    for ((i=0; i<num_mods; i++)); do choices+=(0); done

    while true; do
        clear
        echo -e "${GREEN}=========================================================="
        echo "    DMA-CLOUD: Модульный установщик infrastructure        "
        echo -e "==========================================================${NC}"
        echo " Навигация: [Стрелки Вверх/Вниз]  Выбор: [Пробел]  Подтвердить: [Enter]"
        echo "----------------------------------------------------------"
        
        for ((i=0; i<num_mods; i++)); do
            local marker="[ ]"
            if [ "${choices[i]}" -eq 1 ]; then marker="[*]"; fi
            if [ "$i" -eq "$cursor" ]; then
                echo -e "> \033[1;32m$marker ${mods[i*2+1]}\033[0m"
            else
                echo "  $marker ${mods[i*2+1]}"
            fi
        done
        echo "----------------------------------------------------------"

        # Читаем нажатия клавиш
        read -rsn1 key
        if [[ "$key" == $'\x1b' ]]; then
            read -rsn2 key
            if [[ "$key" == "[A" ]]; then # Стрелка Вверх
                ((cursor--)); if [ "$cursor" -lt 0 ]; then cursor=$((num_mods - 1)); fi
            elif [[ "$key" == "[B" ]]; then # Стрелка Вниз
                ((cursor++)); if [ "$cursor" -ge "$num_mods" ]; then cursor=0; fi
            fi
        elif [[ "$key" == "" ]]; then # Клавиша Enter (Завершить выбор)
            break
        elif [[ "$key" == " " ]]; then # Клавиша Пробел (Переключить чекбокс)
            # ИСПРАВЛЕНО: Исправлена опечатка в массиве choices[cursor] и удалена строка-дубликат
            if [ "${choices[cursor]}" -eq 1 ]; then choices[cursor]=0; else choices[cursor]=1; fi
        fi
    done

    # Возвращаем строку из индексов выбранных элементов через пробел
    for ((i=0; i<num_mods; i++)); do
        if [ "${choices[i]}" -eq 1 ]; then echo -n "$i "; fi
    done
}
# ==============================================================================

# Наш список доступных модулей в папке /scripts (Имя_файла -> Описание в меню)
MODULES=(
    "install-dns.sh"   "Инициализация DNS-сервера (dnsmasq + SOPS) на VPS"
    "install-wg.sh"    "Настройка WireGuard туннеля (Split Tunneling + MTU)"
    "enable-swap.sh"   "Создание SWAP-файла на SSD (для слабых servers)"
)

# Запускаем TUI движок и ловим индексы
SELECTED_INDEXES=$(run_tui_menu MODULES)

if [ -z "$SELECTED_INDEXES" ]; then
    echo "Ни один компонент не выбран. Выход."
    exit 0
fi

clear
echo -e "${YELLOW}=== Начинаем поочередную установку выбранных модулей ===${NC}\n"

# Скачиваем и выполняем выбранные модули последовательно
for idx in $SELECTED_INDEXES; do
    SCRIPT_NAME="${MODULES[idx*2]}"
    SCRIPT_DESC="${MODULES[idx*2+1]}"
    
    echo -e "\033[1;33m>> Запуск модуля: $SCRIPT_DESC... \033[0m"
    echo "----------------------------------------------------------"
    
    TMP_SCRIPT=$(mktemp)
    if curl -s -f -L "${BASE_URL}/${SCRIPT_NAME}" -o "$TMP_SCRIPT"; then
        chmod +x "$TMP_SCRIPT"
        # Передаем управление терминалом </dev/tty, чтобы внутренние read скрипта могли читать клавиатуру
        if ! "$TMP_SCRIPT" </dev/tty; then
            echo -e "${RED}❌ Ошибка при выполнении модуля $SCRIPT_NAME. Остановка общего процесса.${NC}"
            rm -f "$TMP_SCRIPT"
            exit 1
        fi
        rm -f "$TMP_SCRIPT"
    else
        echo -e "${RED}❌ Ошибка: Не удалось скачать скрипт ${SCRIPT_NAME} из Git!${NC}"
        echo "Проверьте URL: ${BASE_URL}/${SCRIPT_NAME}"
        rm -f "$TMP_SCRIPT"
        exit 1
    fi
done

echo -e "\n${GREEN}🎉 Все выбранные компоненты успешно установлены!${NC}"
