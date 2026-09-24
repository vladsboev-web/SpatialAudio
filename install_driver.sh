#!/bin/bash

PKG_PATH="/tmp/BlackHole2ch.pkg"

echo "🎵 Установка виртуального аудиодрайвера BlackHole 2ch..."

if [ ! -f "$PKG_PATH" ]; then
    echo "⬇️ Скачивание BlackHole 2ch..."
    curl -L "https://existential.audio/downloads/BlackHole2ch-0.7.1.pkg" -o "$PKG_PATH"
fi

if [ "$EUID" -eq 0 ]; then
    echo "⚙️ Установка пакета..."
    installer -pkg "$PKG_PATH" -target /
    echo "🔄 Перезапуск CoreAudio демона..."
    killall coreaudiod 2>/dev/null || true
    echo "✅ Драйвер BlackHole успешно установлен!"
else
    echo "🚀 Запуск официального установщика BlackHole..."
    echo "Нажмите 'Продолжить' в появившемся окне и подтвердите установку через Touch ID / пароль."
    open "$PKG_PATH"
fi
