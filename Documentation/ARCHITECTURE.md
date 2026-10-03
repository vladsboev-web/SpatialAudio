# 🏗 Архитектура аудио-пайплайна SpatialAudio

В данном документе описано внутреннее устройство приложения, алгоритмы цифровой обработки сигналов (DSP), синхронизация тактовых генераторов и математические модели нормализации звука.

---

## 1. Общая схема аудио-пайплайна

```
[ Любое приложение macOS ] (Chrome, Spotify, VLC, YouTube, игры)
          │
          ▼ PCM Stereo (44.1 / 48 kHz)
[ BlackHole 2ch ] (Виртуальный HAL аудиодрайвер, loopback без потери качества)
          │
          ▼ Bus 1 Input (Zero-Copy)
[ AudioCaptureUnit ] (AUHAL kAudioUnitSubType_HALOutput)
          │
          ├──► Запись сэмплов Left
          └──► Запись сэмплов Right
          │
          ▼
[ AudioRingBuffer (L & R) ]
    ├─ Pre-roll: 1024 сэмпла (~23 мс)
    ├─ Target Latency: 768 сэмплов (~16-17 мс)
    ├─ Субдискретная линейная интерполяция
    └─ Двусторонняя компенсация дрейфа частот (±0.8% max)
          │
          ▼ Bus 0 Output Callback
[ SpatialEngine ]
    │
    ├──► [ AVAudioSourceNode (Left) ]  ──┐
    │    • renderingAlgorithm = .HRTFHQ  │
    │    • 3D Position (-X, 0, Z)        │
    │                                    ▼
    ├──► [ AVAudioSourceNode (Right) ] ──► [ AVAudioEnvironmentNode ]
    │    • renderingAlgorithm = .HRTFHQ      • listenerPosition = (0, 0, 0)
    │    • 3D Position (+X, 0, Z)            • Factory Reverb: SmallRoom
    │                                        │
    ▼                                        ▼
[ AVAudioUnitEffect (Apple Peak Limiter) ] ◄─┘
    │  (Исключает перегрузки и клиппинг при наложении отражений)
    ▼
[ AVAudioMixerNode ]
    │  • Компенсация затухания: outputVolume = volume * gain * max(1.0, distance)
    ▼
[ AVAudioOutputNode ] (Привязка через auAudioUnit.setDeviceID)
    │
    ▼
[ Наушники / Bluetooth / Внешний ЦАП ] (UGREEN, AirPods, Sony, Built-in Speakers)
```

---

## 2. Компоненты системы

### 2.1. AudioCaptureUnit (`Sources/AudioCaptureUnit.swift`)
- **Тип**: Низкоуровневый AudioUnit типа `kAudioUnitType_Output` / `kAudioUnitSubType_HALOutput`.
- **Конфигурация**:
  - Вход (Bus 1) включен: `kAudioOutputUnitProperty_EnableIO = 1`.
  - Выход (Bus 0) выключен: `kAudioOutputUnitProperty_EnableIO = 0`.
  - Формат потока: 32-bit Float Linear PCM, 2 канала, Non-Interleaved (раздельные буферы для левого и правого каналов).
- **Оптимизация аллокаций**: Буферы `leftScratch`, `rightScratch` и структура `AudioBufferList` предвыделены один раз при инициализации. В рендер-колбэке (`AURenderCallback`) **строго 0 системных вызовов `malloc` / `free`**, что гарантирует отсутствие пропусков кадров (priority inversion).

---

### 2.2. AudioRingBuffer (`Sources/RingBuffer.swift`)
Ключевой модуль, отвечающий за устранение джиттера и рассинхронизации между виртуальным источником (BlackHole) и физическим выводом (Bluetooth-наушники).

- **Емкость**: $2^{16} = 65536$ сэмплов с битовой маской `(capacity - 1)` для мгновенной кольцевой адресации без операции деления.
- **Преднакопление (Pre-roll)**: 1024 сэмпла (~23 мс). Чтение не начнется, пока буфер не заполнится до этой отметки, что полностью защищает от стартового голодания при подключении Bluetooth.
- **Целевая задержка (Target Latency)**: 768 сэмплов (~16.0 мс при 48 кГц, ~17.4 мс при 44.1 кГц).
- **Субдискретная линейная интерполяция**:
  $$\text{sample} = s_0 + \text{frac} \cdot (s_1 - s_0)$$
  Позиция чтения `readPosFrac` является вещественным числом `Double`. Сэмплы считываются не ступенчато, а плавно интерполируются между дискретными отсчетами.
- **Двусторонняя автокомпенсация дрейфа частот (Clock Drift Tracking)**:
  Тактовые генераторы Mac и Bluetooth-наушников никогда не работают на абсолютно одинаковой частоте (разница может составлять 5–20 сэмплов в секунду).
  $$\Delta = \text{currentLag} - \text{targetLatency}$$
  $$\text{speedAdjustment} = \text{clamp}\left(\Delta \times 0.00003, -0.008, +0.008\right)$$
  $$\text{speed} = 1.0 + \text{speedAdjustment}$$
  - Если лаг растет — скорость чтения незаметно ускоряется (до $+0.8\%$).
  - Если лаг падает — скорость чтения плавно замедляется (до $-0.8\%$).
  - При временном исчерпании буфера (`readPosFrac >= writePos`) буфер отдает нули (тишину) без сброса позиции, исключая щелчки.

---

### 2.3. SpatialEngine (`Sources/SpatialEngine.swift`)
Движок пространственного рендеринга на основе `AVAudioEngine` и `AVAudioEnvironmentNode`.

1. **Алгоритм Apple HRTFHQ**:
   - `renderingAlgorithm = .HRTFHQ` (Head-Related Transfer Function High Quality).
   - Аппаратная бинауральная фильтрация Apple, рассчитывающая межушную временную разницу (ITD — Interaural Time Difference) и межушную спектральную разницу (ILD — Interaural Level Difference).
   - Создает реалистичное ощущение расположения колонок в пространстве перед слушателем.

2. **Геометрическое позиционирование**:
   - Слушатель находится в центре координат: $(0, 0, 0)$.
   - Колонки располагаются под углом $\theta$ (`speakerAngleDeg`) на фиксированном эталонном расстоянии $d = 1.0\text{ м}$:
     $$\text{Left} = \left(-\sin(\theta),\, 0,\, -\cos(\theta)\right)$$
     $$\text{Right} = \left(+\sin(\theta),\, 0,\, -\cos(\theta)\right)$$

3. **Истинный уровень громкости (Unity Gain 1:1) и Zero Rolloff**:
   - В ядре CoreAudio параметр затухания расстояния отключен: `rolloffFactor = 0.0`.
   - Громкость пространственного звука строго равна исходной системной громкости macOS ($1:1$) без искусственных множителей и потери динамического диапазона.
   - Ощущение удаленности источников и объема помещения регулируется физическим параметром **Акустики комнаты** (direct-to-reverberant ratio) в диапазоне 0.0%–3.0%.

4. **Защита от клиппинга (Peak Limiter на выходе тракта)**:
   - В самом конце аудиоцепочки (после `mainMixerNode`) установлен системный компонент Apple `kAudioUnitSubType_PeakLimiter`.
   - Он выполняет роль невидимого предохранителя от перегрузок ЦАП при суммировании фаз и пространственных отражений, исключая клиппинг и искажения.

---

## 3. Расчет задержки (End-to-End Latency)

| Сегмент тракта | Задержка (сэмплы) | Время при 44.1 кГц |
| :--- | :--- | :--- |
| CoreAudio BlackHole Buffer | ~128–256 | ~3–5 мс |
| AudioRingBuffer Target Lag | 768 | ~17.4 мс |
| SpatialEngine DSP / Limiter | ~128 | ~2.9 мс |
| **Суммарная внутренняя задержка** | **~1024–1152** | **~23–26 мс** |

*Справка*: Задержка до 40 мс считается стандартом синхронизации речи и артикуляции губ (ITU-R BT.1359-1). Задержка 23–26 мс полностью исключает эффект отставания звука от картинки в фильмах, сериалах и YouTube.
