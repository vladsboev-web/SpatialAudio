#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_DIR="$PROJECT_DIR/Sources"
APP_DIR="$PROJECT_DIR/SpatialAudio.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

echo "🔨 Компиляция SpatialAudio..."

mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Копируем иконку приложения
if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

swiftc -O \
    -framework AppKit \
    -framework SwiftUI \
    -framework AVFoundation \
    -framework CoreAudio \
    -framework AudioToolbox \
    "$SOURCES_DIR/RingBuffer.swift" \
    "$SOURCES_DIR/ProfileManager.swift" \
    "$SOURCES_DIR/AudioDeviceHelper.swift" \
    "$SOURCES_DIR/AudioCaptureUnit.swift" \
    "$SOURCES_DIR/SpatialEngine.swift" \
    "$SOURCES_DIR/AudioCoordinator.swift" \
    "$SOURCES_DIR/SpatialControlView.swift" \
    "$SOURCES_DIR/MenuBarController.swift" \
    "$SOURCES_DIR/main.swift" \
    -o "$MACOS_DIR/SpatialAudio"

echo "📦 Создание Info.plist..."
cat << 'EOF' > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SpatialAudio</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.user.SpatialAudio</string>
    <key>CFBundleName</key>
    <string>SpatialAudio</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>SpatialAudio требует доступ к аудиоустройствам для захвата системного звука из BlackHole.</string>
</dict>
</plist>
EOF

echo "✍️ Подписание приложения..."
# Очищаем временные атрибуты и карантин
xattr -cr "$APP_DIR"

# Подписываем стабильным сертификатом разработки или с явным Designated Requirement
if security find-identity -v -p codesigning | grep -q "SpatialAudio Local"; then
    echo "Используется локальный сертификат: SpatialAudio Local"
    codesign --force --deep -s "SpatialAudio Local" "$APP_DIR"
else
    echo "Используется ad-hoc подпись со стабильным идентификатором"
    codesign --force --deep -s - -r="designated => identifier \"com.user.SpatialAudio\"" "$APP_DIR"
fi

echo "📁 Обновление в /Applications..."
rm -rf "/Applications/SpatialAudio.app"
cp -R "$APP_DIR" "/Applications/SpatialAudio.app"
xattr -cr "/Applications/SpatialAudio.app"

echo "✅ Приложение успешно собрано и установлено в /Applications/SpatialAudio.app"
