#!/bin/bash
set -e

apt update && apt install -y dnsmasq curl gnupg

if command -v sops &> /dev/null; then
    echo "=== [ПРОПУСК] SOPS уже установлен в системе: $(sops --version | head -n 1) ==="
else
    curl -LO https://github.com/getsops/sops/releases/download/v3.13.3/sops-v3.13.3.linux.amd64
    mv sops-v3.13.3.linux.amd64 /usr/local/bin/sops
    chmod +x /usr/local/bin/sops
fi

echo "=== Импорт PGP ключа для SOPS ==="
echo "Вставьте ваш приватный блок ключа (Block) и нажмите Ctrl+D, когда закончите:"
echo "------------------------------------------------------------------------"

if gpg --import; then
    echo "------------------------------------------------------------------------"
    echo "🎉 Ключ успешно импортирован в систему напрямую в память!"
else
    echo "❌ Ошибка импорта ключа."
fi