import SwiftUI
import CoreAudio

public struct SpatialControlView: View {
    @ObservedObject var coordinator = AudioCoordinator.shared
    @ObservedObject var profileManager = ProfileManager.shared
    
    @State private var isCreatingProfile: Bool = false
    @State private var isRenamingProfile: Bool = false
    @State private var newProfileName: String = ""
    @State private var renameProfileName: String = ""
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 12) {
            // БЛОК 1: Заголовок, статус и предупреждение
            headerBlock
            
            // БЛОК 1.5: Профили (CRUD)
            profileBlock
            
            Divider()
            
            // БЛОК 2: Визуализатор звуковой сцены и переключатель
            visualizerBlock
            
            Divider()
            
            // БЛОК 3: Настройки сцены (слайдеры)
            slidersBlock
            
            Divider()
            
            // БЛОК 4: Выбор устройств и индикация уровня
            devicesAndMetersBlock
            
            Divider()
            
            // БЛОК 5: Кнопки управления
            actionsBlock
        }
        .padding(16)
        .frame(width: 320)
    }
    
    // MARK: - Subviews
    
    private var profileBlock: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.2.square")
                    .foregroundColor(.primary)
                    .font(.subheadline)
                
                Text("Профиль:")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                
                Picker("", selection: Binding(
                    get: { profileManager.activeProfileID },
                    set: { newID in
                        if let target = profileManager.profiles.first(where: { $0.id == newID }) {
                            coordinator.applyProfile(target)
                        }
                    }
                )) {
                    ForEach(profileManager.profiles) { p in
                        Text(p.name).tag(p.id)
                    }
                }
                .labelsHidden()
                
                Spacer(minLength: 0)
                
                // Создать новый профиль
                Button(action: {
                    newProfileName = "Профиль \(profileManager.profiles.count + 1)"
                    isRenamingProfile = false
                    isCreatingProfile.toggle()
                }) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
                .help("Создать новый профиль с текущими настройками")
                
                // Переименовать активный профиль
                Button(action: {
                    if let current = profileManager.activeProfile {
                        renameProfileName = current.name
                        isCreatingProfile = false
                        isRenamingProfile.toggle()
                    }
                }) {
                    Image(systemName: "pencil.circle")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundColor(.primary)
                .help("Переименовать текущий профиль")
                
                // Удалить активный профиль (с защитой)
                Button(action: {
                    let idToDelete = profileManager.activeProfileID
                    if profileManager.deleteProfile(id: idToDelete) {
                        if let next = profileManager.activeProfile {
                            coordinator.applyProfile(next)
                        }
                    }
                }) {
                    Image(systemName: "trash.circle")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundColor(profileManager.profiles.count > 1 ? .red : .gray.opacity(0.4))
                .disabled(profileManager.profiles.count <= 1)
                .help(profileManager.profiles.count > 1 ? "Удалить текущий профиль" : "Нельзя удалить единственный профиль")
            }
            
            // Инлайн-поле для создания профиля
            if isCreatingProfile {
                HStack(spacing: 6) {
                    TextField("Имя профиля", text: $newProfileName)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    
                    Button("Создать") {
                        let p = profileManager.createProfile(
                            name: newProfileName,
                            isSpatialEnabled: coordinator.isSpatialEnabled,
                            speakerAngleDeg: coordinator.speakerAngleDeg,
                            distance: coordinator.distance,
                            reverbBlend: coordinator.reverbBlend,
                            volume: coordinator.volume,
                            gainMultiplier: coordinator.gainMultiplier
                        )
                        coordinator.applyProfile(p)
                        isCreatingProfile = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    
                    Button("Отмена") {
                        isCreatingProfile = false
                    }
                    .controlSize(.small)
                }
                .padding(6)
                .background(Color.blue.opacity(0.08))
                .cornerRadius(6)
            }
            
            // Инлайн-поле для переименования профиля
            if isRenamingProfile {
                HStack(spacing: 6) {
                    TextField("Новое имя", text: $renameProfileName)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    
                    Button("Сохранить") {
                        profileManager.renameProfile(id: profileManager.activeProfileID, newName: renameProfileName)
                        isRenamingProfile = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    
                    Button("Отмена") {
                        isRenamingProfile = false
                    }
                    .controlSize(.small)
                }
                .padding(6)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(6)
            }
        }
        .padding(.horizontal, 4)
    }
    
    private var headerBlock: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: coordinator.isRunning ? "person.wave.2.fill" : "person.wave.2")
                    .font(.title2)
                    .foregroundColor(coordinator.isRunning ? .blue : .primary)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spatial Audio")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                    Text("Apple HRTFHQ Engine")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                }
                
                Spacer()
                
                // Индикатор состояния
                HStack(spacing: 6) {
                    Circle()
                        .fill(coordinator.isRunning ? (coordinator.isSpatialEnabled ? Color.green : Color.orange) : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(coordinator.isRunning ? (coordinator.isSpatialEnabled ? "Spatial ON" : "Bypass") : "Пауза")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.08))
                .cornerRadius(12)
            }
            
            // Строка статуса
            HStack {
                Text(coordinator.statusMessage)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(coordinator.isRunning ? .green : .primary)
                Spacer()
            }
            
            if !coordinator.isBlackHoleInstalled {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        Text("Требуется драйвер BlackHole")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                    }
                    Text("Для перехвата звука с Mac установите драйвер BlackHole 2ch:")
                        .font(.caption2)
                        .foregroundColor(.primary)
                    
                    Button(action: {
                        let path = "/tmp/BlackHole2ch.pkg"
                        if FileManager.default.fileExists(atPath: path) {
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        } else {
                            let task = Process()
                            task.launchPath = "/bin/bash"
                            task.arguments = ["-c", "curl -L 'https://existential.audio/downloads/BlackHole2ch-0.7.1.pkg' -o /tmp/BlackHole2ch.pkg && open /tmp/BlackHole2ch.pkg"]
                            task.launch()
                        }
                    }) {
                        HStack {
                            Image(systemName: "arrow.down.circle")
                            Text("Установить BlackHole (в 1 клик)")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.yellow.opacity(0.1))
                .cornerRadius(8)
            }
        }
    }
    
    private var visualizerBlock: some View {
        VStack(spacing: 10) {
            SoundstageVisualizer(
                angle: coordinator.speakerAngleDeg,
                distance: coordinator.distance,
                isEnabled: coordinator.isSpatialEnabled && coordinator.isRunning,
                leftLevel: coordinator.leftLevel,
                rightLevel: coordinator.rightLevel
            )
            .frame(height: 110)
            
            Toggle(isOn: $coordinator.isSpatialEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Пространственное стерео")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Text("Вынос звука из головы (Apple HRTF)")
                        .font(.caption2)
                        .foregroundColor(.primary)
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: .blue))
            .disabled(!coordinator.isRunning)
        }
    }
    
    private var slidersBlock: some View {
        VStack(spacing: 10) {
            // Угол колонок / ширина
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Ширина сцены (угол):")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    Spacer()
                    Text("±\(Int(coordinator.speakerAngleDeg))°")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                }
                Slider(value: $coordinator.speakerAngleDeg, in: 15...60, step: 1)
                    .disabled(!coordinator.isSpatialEnabled || !coordinator.isRunning)
            }
            
            // Дистанция
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Дистанция колонок:")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    Spacer()
                    Text(String(format: "%.1f м", coordinator.distance))
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                }
                Slider(value: $coordinator.distance, in: 0.5...3.0, step: 0.1)
                    .disabled(!coordinator.isSpatialEnabled || !coordinator.isRunning)
            }
            
            // Акустика комнаты
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Акустика комнаты:")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    Spacer()
                    Text(String(format: "%.1f%%", coordinator.reverbBlend * 100))
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                }
                Slider(value: $coordinator.reverbBlend, in: 0.0...0.03, step: 0.001)
                    .disabled(!coordinator.isSpatialEnabled || !coordinator.isRunning)
            }
            
            // Усиление / Громкость
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Усиление громкости:")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    Spacer()
                    Text("\(Int(coordinator.gainMultiplier * 100))%")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                }
                Slider(value: $coordinator.gainMultiplier, in: 0.5...2.0, step: 0.05)
                    .disabled(!coordinator.isRunning)
            }
        }
    }
    
    private var devicesAndMetersBlock: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Вход:")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .frame(width: 50, alignment: .leading)
                
                Picker("", selection: $coordinator.selectedInputDeviceID) {
                    ForEach(coordinator.inputDevices) { dev in
                        let icon = dev.isVirtual ? "🌊 " : "🎤 "
                        Text("\(icon)\(dev.name)").tag(dev.id)
                    }
                }
                .labelsHidden()
                .onChange(of: coordinator.selectedInputDeviceID) { _ in
                    coordinator.restartPipeline()
                }
            }
            
            HStack {
                Text("Выход:")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .frame(width: 50, alignment: .leading)
                
                Picker("", selection: $coordinator.selectedOutputDeviceID) {
                    ForEach(coordinator.outputDevices) { dev in
                        let icon = (dev.isBluetooth || dev.isHeadphones) ? "🎧 " : (dev.isBuiltIn ? "🔊 " : "🔈 ")
                        Text("\(icon)\(dev.name)").tag(dev.id)
                    }
                }
                .labelsHidden()
                .onChange(of: coordinator.selectedOutputDeviceID) { _ in
                    coordinator.restartPipeline()
                }
            }
            
            // Индикаторы аудио-сигнала
            HStack(spacing: 8) {
                Text("L")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                AudioLevelMeter(level: coordinator.leftLevel)
                AudioLevelMeter(level: coordinator.rightLevel)
                Text("R")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
            }
            .padding(.top, 2)
        }
    }
    
    private var actionsBlock: some View {
        HStack(spacing: 10) {
            Button(action: {
                if coordinator.isRunning {
                    coordinator.stopPipeline(restoreSystemAudio: true)
                } else {
                    coordinator.startPipeline()
                }
            }) {
                HStack {
                    Image(systemName: coordinator.isRunning ? "stop.fill" : "play.fill")
                    Text(coordinator.isRunning ? "Остановить" : "Запустить")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(coordinator.isRunning ? .red : .blue)
            
            Button(action: {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Sound.prefPane"))
            }) {
                Image(systemName: "gearshape")
            }
            .help("Настройки звука macOS")
            
            Button(action: {
                coordinator.stopPipeline(restoreSystemAudio: true)
                NSApplication.shared.terminate(nil)
            }) {
                Image(systemName: "power")
            }
            .help("Выйти из приложения")
        }
    }
}

/// Визуализатор звуковой сцены в реальном времени
struct SoundstageVisualizer: View {
    let angle: Double
    let distance: Double
    let isEnabled: Bool
    let leftLevel: Float
    let rightLevel: Float
    
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let centerX = w / 2.0
            let bottomY = h - 18.0
            
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.35))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                
                // Слушатель (голова внизу)
                VStack(spacing: 2) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.cyan)
                    Text("Вы")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                }
                .position(x: centerX, y: bottomY)
                
                // Рассчет положения левой и правой колонок
                let rad = angle * .pi / 180.0
                let normalizedDist = CGFloat((distance - 0.5) / 2.5) // 0 ... 1
                let reach = 35.0 + normalizedDist * 28.0
                
                let lx = centerX - reach * sin(CGFloat(rad))
                let rx = centerX + reach * sin(CGFloat(rad))
                let ly = bottomY - reach * cos(CGFloat(rad))
                let ry = bottomY - reach * cos(CGFloat(rad))
                
                // Лучи от слушателя к колонкам
                Path { path in
                    path.move(to: CGPoint(x: centerX, y: bottomY - 10))
                    path.addLine(to: CGPoint(x: lx, y: ly + 8))
                    path.move(to: CGPoint(x: centerX, y: bottomY - 10))
                    path.addLine(to: CGPoint(x: rx, y: ry + 8))
                }
                .stroke(
                    isEnabled ? Color.blue.opacity(0.4) : Color.gray.opacity(0.2),
                    style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])
                )
                
                // Левая колонка
                SpeakerNode(
                    label: "L",
                    isActive: isEnabled,
                    level: leftLevel
                )
                .position(x: lx, y: ly)
                
                // Правая колонка
                SpeakerNode(
                    label: "R",
                    isActive: isEnabled,
                    level: rightLevel
                )
                .position(x: rx, y: ry)
            }
        }
    }
}

struct SpeakerNode: View {
    let label: String
    let isActive: Bool
    let level: Float
    
    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .fill(isActive ? Color.blue : Color.gray)
                    .frame(width: 18 + CGFloat(level * 8), height: 18 + CGFloat(level * 8))
                    .opacity(0.8)
                    .animation(.easeOut(duration: 0.1), value: level)
                
                Image(systemName: "hifispeaker.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.white)
            }
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
        }
    }
}

struct AudioLevelMeter: View {
    let level: Float
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.green, .yellow, .red],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(level))))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
        .frame(height: 6)
    }
}
