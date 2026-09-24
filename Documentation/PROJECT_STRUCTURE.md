# 📁 Каталог структуры проекта SpatialAudio

В данном документе приведено детальное описание каждого файла, класса, структуры данных и исполняемого скрипта проекта.

---

## 🌳 Дерево каталогов

```
SpatialAudio/
├── Documentation/                 # Полная документация проекта
│   ├── README.md                  # Главная страница документации
│   ├── ARCHITECTURE.md            # Архитектура аудио-пайплайна и DSP
│   ├── PROJECT_STRUCTURE.md       # Этот файл (каталог структуры)
│   ├── SYSTEM_INTEGRATION.md      # Интеграция с macOS, CoreAudio, TCC
│   ├── DIALOG_HISTORY_AND_SOLUTIONS.md # Выжимка истории разработки
│   ├── USER_MANUAL.md             # Руководство пользователя
│   └── ROADMAP_NEXT_STEPS.md      # Планы на следующий чат
├── Resources/                     # Графические ресурсы
│   ├── AppIcon.icns               # Полный многослойный набор иконок macOS
│   └── AppIcon.png                # Исходный мастер-файл 1024x1024 Retina
├── Sources/                       # Исходный код на Swift 5.8+
│   ├── AudioCaptureUnit.swift     # Захват аудио с виртуального драйвера через AUHAL
│   ├── AudioCoordinator.swift     # Главный фасад, синхронизация и CoreAudio слушатели
│   ├── AudioDeviceHelper.swift    # Низкоуровневые утилиты CoreAudio C-API
│   ├── MenuBarController.swift    # Менюбар macOS, реактивная иконка и NSPopover
│   ├── ProfileManager.swift       # CRUD пользовательских профилей и UserDefaults
│   ├── RingBuffer.swift           # Ультра-низколатентный кольцевой буфер с ресемплингом
│   ├── SpatialControlView.swift   # Графический интерфейс SwiftUI (слайдеры, радар, профили)
│   ├── SpatialEngine.swift        # Пространственный движок Apple HRTFHQ (AVAudioEngine)
│   └── main.swift                 # Точка входа в приложение (NSApplicationDelegate)
├── SpatialAudio.app/              # Скомпилированный бандл приложения
├── build_app.sh                   # Скрипт сборки, подписи и установки в /Applications
├── install_driver.sh              # Скрипт проверки и установки драйвера BlackHole 2ch
└── README.md                      # Краткое общее описание репозитория
```

---

## 📄 Описание компонентов исходного кода (`Sources/`)

### 1. `main.swift`
- **Роль**: Точка входа в приложение.
- **Логика**:
  - Переводит приложение в режим строки меню (`NSApp.setActivationPolicy(.accessory)`), скрывая его из Dock и Cmd+Tab.
  - Инициализирует синглтон `AudioCoordinator.shared`.
  - Создает экземпляр `MenuBarController`.
  - При завершении приложения (`applicationWillTerminate`) корректно восстанавливает системное устройство вывода.

---

### 2. `MenuBarController.swift`
- **Роль**: Управление элементом в строке меню macOS (`NSStatusItem`) и всплывающим окном (`NSPopover`).
- **Ключевые свойства и методы**:
  - `statusItem: NSStatusItem?` — элемент менюбара.
  - `popover: NSPopover?` — всплывающее окно SwiftUI.
  - `cancellables: Set<AnyCancellable>` — подписка Combine на `AudioCoordinator.$isRunning`.
  - `updateStatusButton(isRunning: Bool)` — динамическая смена иконки: `person.wave.2.fill` (звук активен) / `person.wave.2` (пауза).
  - `popoverWillShow` / `popoverDidClose` — управление флагом `coordinator.isUIVisible`. Когда окно закрыто, фоновые таймеры обновления измерителей уровня звука выключаются (0% CPU).

---

### 3. `SpatialControlView.swift`
- **Роль**: Главный интерфейс пользователя (SwiftUI).
- **Составные блоки**:
  - `headerBlock`: заголовок, индикатор статуса (Spatial ON / Bypass / Пауза) и текстовое описание состояния.
  - `profileBlock`: селектор профилей, инлайн-создание нового профиля (`plus.circle`), переименование (`pencil.circle`) и удаление (`trash.circle`).
  - `visualizerBlock`: радар звуковой сцены в реальном времени (`SoundstageVisualizer`), отображающий углы и дистанцию виртуальных колонок, а также переключатель режима Spatial Audio / Stereo.
  - `slidersBlock`: интерактивные ползунки угла колонок (15°–60°), дистанции (0.5–3.0 м), реверберации (0–40%), громкости и усиления (+2 dB).
  - `devicesAndMetersBlock`: выбор устройств ввода/вывода и пиковые измерители уровня аудиосигнала (L/R).
  - `actionsBlock`: кнопки «Запустить/Остановить», переход в системные настройки звука и выход из программы.

---

### 4. `AudioCoordinator.swift`
- **Роль**: Центральный диспетчер приложения (State Machine). Синхронизирует аудиопотоки, переключение системных устройств и профили.
- **Ключевые поля**:
  - `isRunning: Bool` — статус активности пайплайна.
  - `selectedOutputDeviceID: AudioDeviceID` — выбранный физический выход (свойство `didSet` автоматически обновляет `savedSystemDefaultOutputDeviceID`).
  - `pendingTargetSystemDefaultID: AudioDeviceID?` — ожидаемый целевой ID при асинхронном переключении.
- **Ключевые методы**:
  - `setupHardwareListeners()` — подписка на системные уведомления CoreAudio (`kAudioHardwarePropertyDevices` и `kAudioHardwarePropertyDefaultOutputDevice`).
  - `handleDefaultOutputDeviceChanged()` — обработка системных сценариев: автопауза при выборе динамиков/других наушников, автостарт с 300 мс стабилизацией при выборе BlackHole.
  - `handleHardwareDevicesChanged()` — горячее подключение новых Bluetooth-наушников или обработка их отключения.
  - `startPipeline(routeSystemAudio: Bool)` — запуск захвата и воспроизведения.
  - `pausePipeline()` — мягкая остановка аудиодвижков без изменения системного устройства.
  - `stopPipeline(restoreSystemAudio: Bool)` — полная остановка с возвратом системного вывода на наушники/динамики.

---

### 5. `SpatialEngine.swift`
- **Роль**: Пространственный процессинг звука на базе `AVAudioEngine`.
- **Ключевые элементы**:
  - `leftSourceNode`, `rightSourceNode: AVAudioSourceNode` — ноды-генераторы, забирающие аудиосэмплы из кольцевого буфера.
  - `environment: AVAudioEnvironmentNode` — пространственная комната с заводским пресетом `smallRoom` и алгоритмом `.HRTFHQ`.
  - `limiterNode: AVAudioUnitEffect` — Apple Peak Limiter для подавления клиппинга.
  - `updateVolume()` — математическая формула компенсации затухания `volume * gain * max(1.0, distance)`.
  - `updateAlgorithmAndPositions()` — пересчет декартовых координат $(X, Y, Z)$ колонок.

---

### 6. `AudioCaptureUnit.swift`
- **Роль**: Захват системного звука из BlackHole с минимальной задержкой.
- **Ключевые элементы**:
  - Аудиоюнит HAL Output с включенным Bus 1 (Input).
  - Предвыделенные статические буферы `leftScratch`, `rightScratch` (до 4096 фреймов).
  - Вызов `AudioUnitRender` и запись сэмплов в кольцевые буферы.
  - Измерение пиковых уровней амплитуды (`peakLevelL`, `peakLevelR`).

---

### 7. `RingBuffer.swift`
- **Роль**: Двусторонний кольцевой буфер с субдискретной интерполяцией и устранением фазовых искажений.
- **Особенности**:
  - Потокобезопасность на `os_unfair_lock`.
  - Адаптивная подстройка скорости ($\pm 0.8\%$) для исключения переполнения и опустошения буфера.
  - Преднакопление 1024 сэмпла для гладкого старта на Bluetooth.

---

### 8. `AudioDeviceHelper.swift`
- **Роль**: Низкоуровневая обертка над C-API CoreAudio.
- **Возможности**:
  - Сканирование всех аудиоустройств (`getAllDevices()`).
  - Определение свойств устройства: Bluetooth, встроенное, виртуальное, наличие входа/выхода.
  - Получение и установка системного устройства по умолчанию (`getDefaultOutputDeviceID`, `setDefaultOutputDevice`).
  - Управление громкостью и размутированием устройства (`setDeviceVolume`).
  - Безопасное чтение и изменение частоты дискретизации без сброса устройства при совпадении частот (`setSampleRate`).

---

### 9. `ProfileManager.swift`
- **Роль**: Персистентное хранилище профилей настроек сцены.
- **Модель**: `SpatialProfile: Codable, Identifiable, Equatable`.
- **Операции**: `createProfile`, `renameProfile`, `deleteProfile`, `updateActiveProfileSettings`, `selectProfile`.
- **Хранилище**: `UserDefaults.standard` в формате JSON.
