#!/bin/bash
set -e

PKG_PATH="${TMPDIR:-/tmp}/BlackHole2ch-0.7.1.pkg"

echo "🎵 Установка виртуального аудиодрайвера BlackHole 2ch..."

if [ ! -f "$PKG_PATH" ] || ! pkgutil --check-signature "$PKG_PATH" >/dev/null 2>&1; then
    rm -f "$PKG_PATH"
    echo "⬇️ Скачивание BlackHole 2ch..."
    curl -fL "https://existential.audio/downloads/BlackHole2ch-0.7.1.pkg" -o "$PKG_PATH"
    pkgutil --check-signature "$PKG_PATH" >/dev/null
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
