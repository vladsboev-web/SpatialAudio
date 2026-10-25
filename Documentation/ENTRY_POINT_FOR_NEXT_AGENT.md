# 🚀 Инструкция и точка входа для агента в новом чате (Agent Entry Point)

> **ПРИМЕЧАНИЕ ДЛЯ АГЕНТА**: Прочти этот документ перед началом работы. Здесь собрана вся контекстная информация, текущее состояние кодовой базы, строгие правила и готовое архитектурное решение для следующей задачи.

---

## 1. 🛡️ Обязательный протокол разработки (`GEMINI.md`)

1. **Режим по умолчанию: Только чтение (Read-Only Analysis)**:
   - При ЛЮБОМ входящем сообщении пользователя с описанием бага, вопроса или проблемы:
     - Работать **ТОЛЬКО В РЕЖИМЕ ЧТЕНИЯ**.
     - Разрешено: просматривать файлы (`view_file`), анализировать первопричины, математику и логику, давать исчерпывающие объяснения в тексте.
     - **СТРОГО ЗАПРЕЩЕНО**: вызывать инструменты записи (`replace_file_content`, `write_to_file`) или запускать сборку/установку через `run_command`.
2. **Явное разрешение пользователя на правки**:
   - Любые изменения файлов и сборка разрешены **ТОЛЬКО И ИСКЛЮЧИТЕЛЬНО**, если последнее сообщение пользователя содержит прямую команду (например, *«делай»*, *«применяй»*, *«разрешаю правки»*).
   - Разрешение из предыдущей задачи **НЕ переносится** на новые репорты.
3. **Строгий запрет Git**:
   - **НИКОГДА** не выполнять `git commit` или `git push` без прямого и явного указания пользователя.

---

## 2. 📍 Текущее состояние кодовой базы

- **Репозиторий**: `/Users/vladislavsboev/Library/Mobile Documents/com~apple~CloudDocs/Проекты/SpatialAudio`
- **Ветка**: `main`
- **Целевая платформа**: macOS 13.0+ (Ventura, Sonoma, Sequoia+), Universal 2 Binary (`arm64` + `x86_64`).
- **Скрипт сборки**: `./build_app.sh` (компилирует, подписывает сертификатом `SpatialAudio Local` и обновляет `/Applications/SpatialAudio.app`).
- **Что было сделано и протестировано**:
  - Архитектура **Single Attenuation**: регулировка громкости F11/F12 идет через CoreAudio на BlackHole; физический ЦАП удерживается на Unity Gain 1.0.
  - Управление громкостью Bluetooth переведено на официальный C-API `AudioHardwareService` (`kVirtualMainVolume`).
  - Ликвидирован 100% удар громкости при переключении: `routeSystemSoundToBlackHole()` сначала переводит системный выход на BlackHole, и только затем раскрывает ЦАП наушников.
  - Устранена двойная аттенюация и потолок громкости (limiter ceiling).
  - Добавлена компенсация затухания Apple HRTFHQ (+4 dB / 1.58x) на микшере `SpatialEngine`.
  - Добавлена подстраховка от отката демоном `bluetoothd` (+0.6s, +1.2s, +2.0s).
  - Устранен Deadlock в `SpatialEngine.resetEngine()` (удален асинхронный `oldEngine.reset()` в фоновом потоке, вызывавший взаимную блокировку CoreAudio HAL).
  - Устранен каскад повторных перезапусков из UI (`SpatialControlView` переведен с `.onChange` на явные `selectInputDeviceByUser` / `selectOutputDeviceByUser`).
  - Реализовано бесшовное подключение и отключение наушников (`isConnectingHeadphones`, `isHandlingDeviceDisconnection`, фильтрация служебных `CADefaultDeviceAggregate` по `lastKnownHardwareDeviceIDs`).
  - Оптимизированы `AudioDeviceHelper.setDeviceVolume` (без дублирования IPC) и `AudioCaptureUnit` (SIMD `vDSP_maxmgv`).

---

## 3. 🎯 Актуальная задача: баг «Отключаю наушники — тишина»

### Суть проблемы
Когда пользователь отключает Bluetooth-наушники (убирает AirPods в кейс или отключает Bluetooth), звук не переключается автоматически на встроенные динамики Mac, а наступает полная тишина.

### Детальная первопричина
1. В [`Sources/AudioCoordinator.swift`](file:///Users/vladislavsboev/Library/Mobile%20Documents/com~apple~CloudDocs/Проекты/SpatialAudio/Sources/AudioCoordinator.swift) при отключении наушников система CoreAudio генерирует событие `kAudioHardwarePropertyDefaultOutputDevice`.
2. macOS видит, что наушники отключились, и автоматически назначает системным устройством встроенные динамики (`Built-in Output`).
3. Метод `handleDefaultOutputDeviceChanged()` ловит это событие:
   ```swift
   if let bh = bh, currentDefault == bh.id {
       // ...
   } else {
       // ⏸ Сценарий 2: Пользователь явно выбрал в системном меню macOS другой источник
       if self.isRunning {
           // ...
           self.pausePipeline() // <- ПАЙПЛАЙН ПРИНУДИТЕЛЬНО СТАВИТСЯ НА ПАУЗУ!
           self.statusMessage = "Приостановлено (\(devName))"
       }
   }
   ```
4. Логика считает системный автоматический сброс выхода на динамики «ручным выбором пользователя» и останавливает пайплайн. В итоге звук не идет ни через BlackHole, ни в динамики.

### Готовое архитектурное решение для исправления
В [`Sources/AudioCoordinator.swift`](file:///Users/vladislavsboev/Library/Mobile%20Documents/com~apple~CloudDocs/Проекты/SpatialAudio/Sources/AudioCoordinator.swift):
1. **Ввести флаг отключения устройства**:
   - В `handleHardwareDevicesChanged()` обнаруживать не только подключение, но и факт исчезновения текущего `selectedOutputDeviceID`. Устанавливать флаг `isHandlingDeviceDisconnection = true`.
2. **В `handleDefaultOutputDeviceChanged()` игнорировать системный сброс дефолта во время отключения**:
   - Если `isHandlingDeviceDisconnection == true`, не вызывать `pausePipeline()`, а позволить `performHardwareDevicesChanged()` выполнить штатный fallback.
3. **Бесшовный Fallback в `performHardwareDevicesChanged()`**:
   - При отключении текущих наушников:
     1. Найти `fallbackDev` (предыдущее устройство или `AudioDeviceHelper.findPreferredOutputDevice()`, обычно Built-in Output).
     2. Назначить `selectedOutputDeviceID = fallback.id`.
     3. Немедленно удержать `BlackHole 2ch` в качестве `DefaultOutputDevice`.
     4. Перезапустить аудио-юниты на динамики через `startPipeline(routeSystemAudio: true)` с сохранением `isRunning = true`.
     5. Сбросить флаг `isHandlingDeviceDisconnection = false`.

---

## 4. 🛠️ Памятка по командам проверки и сборки

```bash
# 1. Проверка текущих устройств CoreAudio и громкостей
system_profiler SPAudioDataType

# 2. Сборка приложения (Universal 2 Binary)
./build_app.sh

# 3. Перезапуск процесса
killall SpatialAudio || true
open /Applications/SpatialAudio.app

# 4. Просмотр логов процесса в реальном времени
/usr/bin/log stream --predicate 'process == "SpatialAudio"' --level debug
```
