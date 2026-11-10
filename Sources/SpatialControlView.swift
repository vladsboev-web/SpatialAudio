import SwiftUI
import CoreAudio

// MARK: - Тактильный стиль кнопок (быстрый плавный отклик при наведении и клике)

public struct TactileButtonStyle: ButtonStyle {
    @State private var isHovered = false
    
    public init() {}
    
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : (isHovered ? 1.022 : 1.0))
            .animation(.spring(response: 0.13, dampingFraction: 0.78), value: configuration.isPressed)
            .animation(.spring(response: 0.15, dampingFraction: 0.80), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

// MARK: - Кастомные минималистичные векторные иконки в едином стиле

/// Минималистичная иконка наушников
struct MinimalHeadphonesIcon: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let stroke = StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round)
            
            var headband = Path()
            headband.addArc(
                center: CGPoint(x: w * 0.5, y: h * 0.52),
                radius: w * 0.34,
                startAngle: .degrees(180),
                endAngle: .degrees(0),
                clockwise: false
            )
            ctx.stroke(headband, with: .foreground, style: stroke)
            
            let cupW = w * 0.17
            let cupH = h * 0.30
            let cupY = h * 0.50
            let leftRect = CGRect(x: w * 0.12, y: cupY, width: cupW, height: cupH)
            let rightRect = CGRect(x: w * 0.88 - cupW, y: cupY, width: cupW, height: cupH)
            
            ctx.stroke(Path(roundedRect: leftRect, cornerRadius: 2.5), with: .foreground, style: stroke)
            ctx.stroke(Path(roundedRect: rightRect, cornerRadius: 2.5), with: .foreground, style: stroke)
        }
    }
}

/// Минималистичная иконка стереопары колонок в едином стиле
struct MinimalSpeakersIcon: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let stroke = StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round)
            
            let boxW = w * 0.31
            let boxH = h * 0.68
            let boxY = h * 0.16
            let leftBox = CGRect(x: w * 0.11, y: boxY, width: boxW, height: boxH)
            let rightBox = CGRect(x: w * 0.89 - boxW, y: boxY, width: boxW, height: boxH)
            
            for rect in [leftBox, rightBox] {
                ctx.stroke(Path(roundedRect: rect, cornerRadius: 2.5), with: .foreground, style: stroke)
                
                // ВЧ-твитер (точка)
                let tweeterR: CGFloat = 1.2
                let tweeterRect = CGRect(
                    x: rect.midX - tweeterR,
                    y: rect.minY + rect.height * 0.27 - tweeterR,
                    width: tweeterR * 2,
                    height: tweeterR * 2
                )
                ctx.fill(Path(ellipseIn: tweeterRect), with: .foreground)
                
                // НЧ-диффузор (кольцо)
                let wooferR = rect.width * 0.26
                let wooferRect = CGRect(
                    x: rect.midX - wooferR,
                    y: rect.minY + rect.height * 0.67 - wooferR,
                    width: wooferR * 2,
                    height: wooferR * 2
                )
                ctx.stroke(Path(ellipseIn: wooferRect), with: .foreground, style: StrokeStyle(lineWidth: 1.6))
            }
        }
    }
}

/// Минималистичная иконка темы (Солнце / Полумесяц)
struct MinimalThemeIcon: View {
    let isDark: Bool
    
    var body: some View {
        if isDark {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(red: 0.40, green: 0.85, blue: 0.98))
        } else {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(red: 0.96, green: 0.62, blue: 0.04))
        }
    }
}

// MARK: - Кастомные выпадающие списки в стиле приложения (внешний вид кнопки и открытого меню)

private enum ActiveDropdownMenu: Hashable {
    case profile
    case inputDevice
    case outputDevice
}

private struct DropdownTriggerFramePreferenceKey: PreferenceKey {
    static var defaultValue: [ActiveDropdownMenu: CGRect] = [:]
    static func reduce(value: inout [ActiveDropdownMenu: CGRect], nextValue: () -> [ActiveDropdownMenu: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Кнопка закрытого выпадающего списка (в едином стеклянном/карточном стиле приложения)
private struct StyledDropdownTrigger: View {
    let menuKind: ActiveDropdownMenu
    let iconSymbol: String?
    let title: String
    let isOpen: Bool
    let isDark: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    private var primaryText: Color {
        isDark ? .white : Color(red: 0.08, green: 0.11, blue: 0.18)
    }
    
    private var accentColor: Color {
        Color(red: 0.18, green: 0.72, blue: 0.98)
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let iconSymbol = iconSymbol {
                    Image(systemName: iconSymbol)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(isOpen ? accentColor : primaryText.opacity(0.75))
                        .frame(width: 15)
                }
                
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                Spacer(minLength: 4)
                
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(isOpen ? accentColor : primaryText.opacity(0.55))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6.5)
            .background(
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            isOpen
                                ? accentColor.opacity(isDark ? 0.18 : 0.14)
                                : primaryText.opacity(isHovered ? (isDark ? 0.12 : 0.09) : (isDark ? 0.075 : 0.055))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(
                                    isOpen
                                        ? accentColor.opacity(0.65)
                                        : primaryText.opacity(isHovered ? 0.18 : 0.08),
                                    lineWidth: 1
                                )
                        )
                        .preference(
                            key: DropdownTriggerFramePreferenceKey.self,
                            value: [menuKind: geo.frame(in: .named("windowSpace"))]
                        )
                }
            )
            .scaleEffect(isHovered ? 1.01 : 1.0)
            .animation(.spring(response: 0.14, dampingFraction: 0.82), value: isOpen)
            .animation(.spring(response: 0.12, dampingFraction: 0.82), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

/// Строка внутри открытого кастомного выпадающего списка
private struct StyledDropdownOptionRow: View {
    let iconSymbol: String
    let title: String
    let isSelected: Bool
    let isDark: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    private var primaryText: Color {
        isDark ? .white : Color(red: 0.08, green: 0.11, blue: 0.18)
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            isSelected
                                ? Color.white.opacity(0.22)
                                : primaryText.opacity(isDark ? 0.08 : 0.06)
                        )
                        .frame(width: 24, height: 24)
                    
                    Image(systemName: iconSymbol)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(
                            isSelected
                                ? .white
                                : Color(red: 0.18, green: 0.68, blue: 0.96)
                        )
                }
                
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                    .foregroundColor(isSelected ? .white : primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                Spacer(minLength: 6)
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6.5)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isSelected
                            ? LinearGradient(
                                colors: [Color(red: 0.18, green: 0.52, blue: 0.98), Color(red: 0.12, green: 0.75, blue: 0.95)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            : LinearGradient(
                                colors: [
                                    primaryText.opacity(isHovered ? (isDark ? 0.10 : 0.07) : 0.0),
                                    primaryText.opacity(isHovered ? (isDark ? 0.10 : 0.07) : 0.0)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                    )
            )
            .scaleEffect(isHovered && !isSelected ? 1.01 : 1.0)
            .animation(.spring(response: 0.13, dampingFraction: 0.8), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Фоновые градиентные аудио-волны из нижних углов (строго под плашками, реальная физика вперед)

private struct CornerWavePacket {
    var radius: CGFloat
    let maxRadius: CGFloat
    let speed: CGFloat
    let energy: CGFloat
    let color: Color
}

struct BackgroundCornerWavesView: View {
    let leftLevel: Float
    let rightLevel: Float
    let isActive: Bool
    let isDark: Bool
    
    @State private var wavesL: [CornerWavePacket] = []
    @State private var wavesR: [CornerWavePacket] = []
    @State private var tickCounter: Int = 0
    
    /// Цвет из прошлой версии (изумрудно-бирюзовый -> насыщенный циан -> ярко-синий/индиго)
    private func waveColor(for level: CGFloat) -> Color {
        if level < 0.55 {
            return isDark
                ? Color(red: 0.06, green: 0.73, blue: 0.51)
                : Color(red: 0.05, green: 0.65, blue: 0.91)
        } else if level < 0.82 {
            return isDark
                ? Color(red: 0.22, green: 0.74, blue: 0.97)
                : Color(red: 0.01, green: 0.52, blue: 0.78)
        } else {
            return isDark
                ? Color(red: 0.39, green: 0.40, blue: 0.95)
                : Color(red: 0.23, green: 0.51, blue: 0.96)
        }
    }
    
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let lvlL = CGFloat(leftLevel)
            let lvlR = CGFloat(rightLevel)
            
            Canvas { ctx, size in
                guard isActive else { return }
                
                // 1. Мгновенное свечение в самих нижних углах в такт полосам L / R (без задержки)
                if lvlL > 0.02 {
                    let coreR = 50.0 + lvlL * 110.0
                    let cL = waveColor(for: lvlL)
                    let alpha = Double(lvlL) * (isDark ? 0.52 : 0.38)
                    let center = CGPoint(x: 0, y: h)
                    let rect = CGRect(x: -coreR, y: h - coreR, width: coreR * 2, height: coreR * 2)
                    ctx.fill(
                        Path(ellipseIn: rect),
                        with: .radialGradient(
                            Gradient(colors: [cL.opacity(alpha), cL.opacity(alpha * 0.35), .clear]),
                            center: center,
                            startRadius: 2,
                            endRadius: coreR
                        )
                    )
                }
                
                if lvlR > 0.02 {
                    let coreR = 50.0 + lvlR * 110.0
                    let cR = waveColor(for: lvlR)
                    let alpha = Double(lvlR) * (isDark ? 0.52 : 0.38)
                    let center = CGPoint(x: w, y: h)
                    let rect = CGRect(x: w - coreR, y: h - coreR, width: coreR * 2, height: coreR * 2)
                    ctx.fill(
                        Path(ellipseIn: rect),
                        with: .radialGradient(
                            Gradient(colors: [cR.opacity(alpha), cR.opacity(alpha * 0.35), .clear]),
                            center: center,
                            startRadius: 2,
                            endRadius: coreR
                        )
                    )
                }
                
                // 2. Расходящиеся вперед градиентные гребни волн из левого угла (L)
                let originL = CGPoint(x: 0, y: h)
                for wv in wavesL {
                    let progress = wv.radius / max(1.0, wv.maxRadius)
                    let alpha = Double((1.0 - progress) * wv.energy) * (isDark ? 0.44 : 0.32)
                    guard alpha > 0.005 else { continue }
                    
                    let thickness: CGFloat = 52.0 + wv.energy * 38.0
                    let innerR = max(2.0, wv.radius - thickness * 0.5)
                    let outerR = wv.radius + thickness * 0.5
                    let rect = CGRect(x: -outerR, y: h - outerR, width: outerR * 2, height: outerR * 2)
                    
                    ctx.fill(
                        Path(ellipseIn: rect),
                        with: .radialGradient(
                            Gradient(colors: [.clear, wv.color.opacity(alpha), .clear]),
                            center: originL,
                            startRadius: innerR,
                            endRadius: outerR
                        )
                    )
                }
                
                // 3. Расходящиеся вперед градиентные гребни волн из правого угла (R)
                let originR = CGPoint(x: w, y: h)
                for wv in wavesR {
                    let progress = wv.radius / max(1.0, wv.maxRadius)
                    let alpha = Double((1.0 - progress) * wv.energy) * (isDark ? 0.44 : 0.32)
                    guard alpha > 0.005 else { continue }
                    
                    let thickness: CGFloat = 52.0 + wv.energy * 38.0
                    let innerR = max(2.0, wv.radius - thickness * 0.5)
                    let outerR = wv.radius + thickness * 0.5
                    let rect = CGRect(x: w - outerR, y: h - outerR, width: outerR * 2, height: outerR * 2)
                    
                    ctx.fill(
                        Path(ellipseIn: rect),
                        with: .radialGradient(
                            Gradient(colors: [.clear, wv.color.opacity(alpha), .clear]),
                            center: originR,
                            startRadius: innerR,
                            endRadius: outerR
                        )
                    )
                }
            }
            // Обновление физики волн строго когда окно активно (когда поповер закрыт, таймер не тикает -> 0% CPU)
            .onReceive(Timer.publish(every: 0.04, on: .main, in: .common).autoconnect()) { _ in
                guard isActive else {
                    if !wavesL.isEmpty { wavesL.removeAll() }
                    if !wavesR.isEmpty { wavesR.removeAll() }
                    return
                }
                if leftLevel > 0.005 || rightLevel > 0.005 || !wavesL.isEmpty || !wavesR.isEmpty {
                    stepWavePhysics(height: h)
                }
            }
            .onChange(of: isActive) { active in
                if !active {
                    wavesL.removeAll()
                    wavesR.removeAll()
                }
            }
        }
        .allowsHitTesting(false)
    }
    
    private func stepWavePhysics(height: CGFloat) {
        guard isActive else {
            if !wavesL.isEmpty { wavesL.removeAll() }
            if !wavesR.isEmpty { wavesR.removeAll() }
            return
        }
        
        tickCounter += 1
        let l = CGFloat(leftLevel)
        let r = CGFloat(rightLevel)
        
        // Каждые 3 тика (~120 мс) рождаем новый гребень волны в углу, если есть сигнал (максимум 5 активных волн на угол для легкости)
        if tickCounter % 3 == 0 {
            if l > 0.04 && wavesL.count < 5 {
                wavesL.append(CornerWavePacket(
                    radius: 14.0,
                    maxRadius: 150.0 + l * (height * 0.92),
                    speed: 6.5 + l * 6.5,
                    energy: l,
                    color: waveColor(for: l)
                ))
            }
            if r > 0.04 && wavesR.count < 5 {
                wavesR.append(CornerWavePacket(
                    radius: 14.0,
                    maxRadius: 150.0 + r * (height * 0.92),
                    speed: 6.5 + r * 6.5,
                    energy: r,
                    color: waveColor(for: r)
                ))
            }
        }
        
        // Двигаем все существующие волны строго вперед снизу вверх
        for i in wavesL.indices.reversed() {
            wavesL[i].radius += wavesL[i].speed
            if wavesL[i].radius >= wavesL[i].maxRadius {
                wavesL.remove(at: i)
            }
        }
        for i in wavesR.indices.reversed() {
            wavesR[i].radius += wavesR[i].speed
            if wavesR[i].radius >= wavesR[i].maxRadius {
                wavesR.remove(at: i)
            }
        }
    }
}

// MARK: - Главное окно управления SpatialControlView

public struct SpatialControlView: View {
    @ObservedObject var coordinator = AudioCoordinator.shared
    @ObservedObject var profileManager = ProfileManager.shared
    @ObservedObject var l10n = LocalizationManager.shared
    @ObservedObject var themeManager = ThemeManager.shared
    
    @State private var isCreatingProfile: Bool = false
    @State private var isRenamingProfile: Bool = false
    @State private var isDownloadingBlackHole: Bool = false
    @State private var newProfileName: String = ""
    @State private var renameProfileName: String = ""
    @State private var activeDropdown: ActiveDropdownMenu? = nil
    @State private var triggerFrames: [ActiveDropdownMenu: CGRect] = [:]
    @FocusState private var isProfileTextFieldFocused: Bool
    
    public init() {}
    
    private var isDark: Bool {
        themeManager.isDark
    }
    
    // Палитра темы (плотные карточки поверх фоновых волн, чтобы волны шли строго ПОД плашками)
    private var windowBgColor: Color {
        isDark ? Color(red: 0.055, green: 0.067, blue: 0.098) : Color(red: 0.90, green: 0.925, blue: 0.96)
    }
    
    private var cardBgColor: Color {
        isDark ? Color(red: 0.11, green: 0.13, blue: 0.185).opacity(0.95) : Color.white.opacity(0.96)
    }
    
    private var dropdownMenuBgColor: Color {
        isDark ? Color(red: 0.09, green: 0.11, blue: 0.16).opacity(0.98) : Color.white.opacity(0.99)
    }
    
    private var cardBorderColor: Color {
        isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.10)
    }
    
    private var primaryTextColor: Color {
        isDark ? Color.white : Color(red: 0.08, green: 0.11, blue: 0.18)
    }
    
    private var secondaryTextColor: Color {
        isDark ? Color.white.opacity(0.65) : Color(red: 0.30, green: 0.36, blue: 0.46)
    }
    
    private func inputDeviceSymbol(for dev: AudioDevice) -> String {
        dev.isVirtual ? "waveform.circle.fill" : "mic.fill"
    }
    
    private func outputDeviceSymbol(for dev: AudioDevice) -> String {
        if dev.isBluetooth || dev.isHeadphones {
            return "headphones"
        } else if dev.isBuiltIn {
            return "hifispeaker.2.fill"
        } else {
            return "speaker.wave.2.fill"
        }
    }
    
    public var body: some View {
        ZStack(alignment: .top) {
            // СЛОЙ 0: Подложка окна + Фоновые аудио-волны из нижних углов L/R снизу вверх
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(windowBgColor)
            
            BackgroundCornerWavesView(
                leftLevel: coordinator.leftLevel,
                rightLevel: coordinator.rightLevel,
                isActive: coordinator.isRunning && coordinator.isUIVisible,
                isDark: isDark
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            
            // СЛОЙ 1: Плотные карточки интерфейса поверх фоновых волн
            VStack(spacing: 10) {
                headerCard
                
                if !coordinator.isBlackHoleInstalled {
                    blackHoleBannerCard
                }
                
                profileAndModeRow
                
                if isCreatingProfile || isRenamingProfile {
                    profileInlineEditorCard
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }
                
                visualizerCard
                
                slidersCard
                
                devicesAndMetersCard
                
                footerCard
            }
            .padding(14)
            
            // СЛОЙ 2: Кастомные открытые выпадающие списки поверх карточек (привязанные точно к координатам своих кнопок)
            if let currentDropdown = activeDropdown {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.14, dampingFraction: 0.85)) {
                            activeDropdown = nil
                        }
                    }
                    .zIndex(15)
                
                dropdownOverlayPanel(for: currentDropdown)
                    .transition(
                        .opacity.combined(
                            with: .scale(
                                scale: 0.96,
                                anchor: currentDropdown == .profile ? .top : .bottom
                            )
                        )
                    )
                    .zIndex(20)
            }
        }
        .coordinateSpace(name: "windowSpace")
        .onPreferenceChange(DropdownTriggerFramePreferenceKey.self) { frames in
            triggerFrames = frames
        }
        .frame(width: 344)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.12), lineWidth: 1)
        )
        .preferredColorScheme(isDark ? .dark : .light)
        .animation(.spring(response: 0.20, dampingFraction: 0.84), value: isDark)
        .animation(.spring(response: 0.18, dampingFraction: 0.84), value: coordinator.isSpeakerMode)
        .animation(.spring(response: 0.18, dampingFraction: 0.84), value: isCreatingProfile)
        .animation(.spring(response: 0.18, dampingFraction: 0.84), value: isRenamingProfile)
        .onChange(of: coordinator.isUIVisible) { visible in
            if !visible {
                activeDropdown = nil
                isCreatingProfile = false
                isRenamingProfile = false
            }
        }
        .onChange(of: coordinator.isSpeakerMode) { _ in
            isCreatingProfile = false
            isRenamingProfile = false
            activeDropdown = nil
        }
    }
    
    // MARK: - Кастомная всплывающая карточка открытого выпадающего списка (точно над или под своей кнопкой)
    
    @ViewBuilder
    private func dropdownOverlayPanel(for menu: ActiveDropdownMenu) -> some View {
        switch menu {
        case .profile:
            let rect = triggerFrames[.profile] ?? CGRect(x: 24, y: 98, width: 176, height: 30)
            let menuWidth = max(196.0, rect.width)
            
            VStack(alignment: .leading, spacing: 4) {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 3) {
                        ForEach(profileManager.profiles) { p in
                            StyledDropdownOptionRow(
                                iconSymbol: "slider.horizontal.3",
                                title: p.name,
                                isSelected: p.id == profileManager.activeProfileID,
                                isDark: isDark
                            ) {
                                withAnimation(.spring(response: 0.14, dampingFraction: 0.85)) {
                                    coordinator.applyProfile(p)
                                    activeDropdown = nil
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: min(CGFloat(max(1, profileManager.profiles.count)) * 38.0, 190.0))
            }
            .padding(6)
            .frame(width: menuWidth)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(dropdownMenuBgColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(Color(red: 0.18, green: 0.72, blue: 0.98).opacity(0.55), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(isDark ? 0.50 : 0.16), radius: 12, x: 0, y: 6)
            )
            // Открывается ровно под кнопкой выбора профиля (с отступом 5pt)
            .offset(x: rect.minX, y: rect.maxY + 5.0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            
        case .inputDevice:
            let rect = triggerFrames[.inputDevice] ?? CGRect(x: 82, y: 382, width: 236, height: 30)
            let itemCount = max(1, coordinator.inputDevices.count)
            let scrollH = min(CGFloat(itemCount) * 38.0 + CGFloat(max(0, itemCount - 1)) * 3.0, 175.0)
            let totalH = scrollH + 12.0
            // Открывается ровно НАД кнопкой «Вход» (вплотную, с отступом 5pt) и строго по её ширине и X-координате
            let menuY = max(14.0, rect.minY - totalH - 5.0)
            
            VStack(alignment: .leading, spacing: 0) {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 3) {
                        ForEach(coordinator.inputDevices) { dev in
                            StyledDropdownOptionRow(
                                iconSymbol: inputDeviceSymbol(for: dev),
                                title: dev.name,
                                isSelected: dev.id == coordinator.selectedInputDeviceID,
                                isDark: isDark
                            ) {
                                withAnimation(.spring(response: 0.14, dampingFraction: 0.85)) {
                                    coordinator.selectInputDeviceByUser(dev.id)
                                    activeDropdown = nil
                                }
                            }
                        }
                    }
                }
                .frame(height: scrollH)
            }
            .padding(6)
            .frame(width: rect.width)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(dropdownMenuBgColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(Color(red: 0.18, green: 0.72, blue: 0.98).opacity(0.55), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(isDark ? 0.50 : 0.16), radius: 12, x: 0, y: -4)
            )
            .offset(x: rect.minX, y: menuY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            
        case .outputDevice:
            let rect = triggerFrames[.outputDevice] ?? CGRect(x: 82, y: 420, width: 236, height: 30)
            let itemCount = max(1, coordinator.outputDevices.count)
            let scrollH = min(CGFloat(itemCount) * 38.0 + CGFloat(max(0, itemCount - 1)) * 3.0, 185.0)
            let totalH = scrollH + 12.0
            // Открывается ровно НАД кнопкой «Выход» (вплотную, с отступом 5pt) и строго по её ширине и X-координате
            let menuY = max(14.0, rect.minY - totalH - 5.0)
            
            VStack(alignment: .leading, spacing: 0) {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 3) {
                        ForEach(coordinator.outputDevices) { dev in
                            StyledDropdownOptionRow(
                                iconSymbol: outputDeviceSymbol(for: dev),
                                title: dev.name,
                                isSelected: dev.id == coordinator.selectedOutputDeviceID,
                                isDark: isDark
                            ) {
                                withAnimation(.spring(response: 0.14, dampingFraction: 0.85)) {
                                    coordinator.selectOutputDeviceByUser(dev.id)
                                    activeDropdown = nil
                                }
                            }
                        }
                    }
                }
                .frame(height: scrollH)
            }
            .padding(6)
            .frame(width: rect.width)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(dropdownMenuBgColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(Color(red: 0.18, green: 0.72, blue: 0.98).opacity(0.55), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(isDark ? 0.50 : 0.16), radius: 12, x: 0, y: -4)
            )
            .offset(x: rect.minX, y: menuY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
    
    // MARK: - 1. Шапка: Бренд + Язык + Статус | Переключатель темы + Кнопка Активно
    
    private var headerCard: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: coordinator.isRunning
                                ? [Color(red: 0.18, green: 0.50, blue: 0.98), Color(red: 0.14, green: 0.82, blue: 0.95)]
                                : [Color.gray.opacity(0.45), Color.gray.opacity(0.30)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)
                    .shadow(color: coordinator.isRunning ? Color.blue.opacity(0.30) : .clear, radius: 6, x: 0, y: 3)
                
                Image(systemName: coordinator.isRunning ? "person.wave.2.fill" : "person.wave.2")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Spatial Audio")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(primaryTextColor)
                    
                    Button(action: {
                        withAnimation(.spring(response: 0.18, dampingFraction: 0.8)) {
                            l10n.toggleLanguage()
                        }
                    }) {
                        Text(l10n.language.badgeTitle)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(primaryTextColor.opacity(0.85))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(primaryTextColor.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(TactileButtonStyle())
                    .help(L10n.languageToggleHelp)
                }
                
                HStack(spacing: 5) {
                    Circle()
                        .fill(coordinator.isRunning ? Color(red: 0.16, green: 0.85, blue: 0.55) : Color.gray)
                        .frame(width: 6.5, height: 6.5)
                    
                    Text(coordinator.statusMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(secondaryTextColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            
            Spacer(minLength: 4)
            
            // Кнопка переключения темы Светлая / Тёмная (слева от кнопки Активно)
            Button(action: {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                    themeManager.toggleTheme()
                }
            }) {
                ZStack {
                    Circle()
                        .fill(primaryTextColor.opacity(0.08))
                        .frame(width: 30, height: 30)
                        .overlay(
                            Circle()
                                .stroke(cardBorderColor, lineWidth: 1)
                        )
                    
                    MinimalThemeIcon(isDark: isDark)
                }
            }
            .buttonStyle(TactileButtonStyle())
            .help(L10n.themeToggleHelp)
            
            // Кнопка Активно / Запустить
            Button(action: {
                withAnimation(.spring(response: 0.20, dampingFraction: 0.78)) {
                    if coordinator.isRunning {
                        coordinator.stopPipeline(restoreSystemAudio: true)
                    } else {
                        coordinator.startPipeline()
                    }
                }
            }) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 6, height: 6)
                    Text(coordinator.isRunning ? L10n.activeBtnTitle : L10n.startBtn)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(
                    Capsule()
                        .fill(
                            coordinator.isRunning
                                ? LinearGradient(colors: [Color(red: 0.18, green: 0.52, blue: 0.98), Color(red: 0.12, green: 0.72, blue: 0.94)], startPoint: .leading, endPoint: .trailing)
                                : LinearGradient(colors: [Color.gray.opacity(0.65), Color.gray.opacity(0.50)], startPoint: .leading, endPoint: .trailing)
                        )
                )
                .shadow(color: coordinator.isRunning ? Color.blue.opacity(0.28) : .clear, radius: 5, x: 0, y: 2)
            }
            .buttonStyle(TactileButtonStyle())
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardBgColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(cardBorderColor, lineWidth: 1)
                )
        )
    }
    
    // MARK: - Баннер установки BlackHole (если не установлен)
    
    private var blackHoleBannerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                Text(L10n.blackHoleRequiredTitle)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(primaryTextColor)
            }
            Text(L10n.blackHoleRequiredDesc)
                .font(.caption2)
                .foregroundColor(secondaryTextColor)
            
            Button(action: {
                guard !isDownloadingBlackHole else { return }
                let pkgURL = FileManager.default.temporaryDirectory.appendingPathComponent("BlackHole2ch-0.7.1.pkg")
                if FileManager.default.fileExists(atPath: pkgURL.path),
                   Self.verifyInstallerSignature(at: pkgURL.path) {
                    NSWorkspace.shared.open(pkgURL)
                    return
                }
                try? FileManager.default.removeItem(at: pkgURL)
                isDownloadingBlackHole = true
                DispatchQueue.global(qos: .userInitiated).async {
                    let dlTask = Process()
                    dlTask.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                    dlTask.arguments = ["-fL", "https://existential.audio/downloads/BlackHole2ch-0.7.1.pkg", "-o", pkgURL.path]
                    do {
                        try dlTask.run()
                        dlTask.waitUntilExit()
                        let ok = (dlTask.terminationStatus == 0) && Self.verifyInstallerSignature(at: pkgURL.path)
                        DispatchQueue.main.async {
                            isDownloadingBlackHole = false
                            if ok {
                                NSWorkspace.shared.open(pkgURL)
                            } else {
                                try? FileManager.default.removeItem(at: pkgURL)
                            }
                        }
                    } catch {
                        DispatchQueue.main.async {
                            isDownloadingBlackHole = false
                        }
                    }
                }
            }) {
                HStack {
                    if isDownloadingBlackHole {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle")
                    }
                    Text(L10n.installBlackHoleBtn)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isDownloadingBlackHole)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(cardBgColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.yellow.opacity(0.45), lineWidth: 1)
                )
        )
    }
    
    // MARK: - 2. Профиль (название под словом «Профиль») + Крупные минималистичные иконки Наушники/Колонки
    
    private var profileAndModeRow: some View {
        HStack(spacing: 8) {
            // Левая карточка: Профиль (двустрочная, с кастомным выпадающим списком)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(L10n.profileHeaderLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(secondaryTextColor)
                    
                    Spacer(minLength: 0)
                    
                    // Создать профиль
                    Button(action: {
                        activeDropdown = nil
                        newProfileName = L10n.newProfileDefaultName(profileManager.profiles.count + 1)
                        isRenamingProfile = false
                        isCreatingProfile.toggle()
                        if isCreatingProfile {
                            DispatchQueue.main.async { isProfileTextFieldFocused = true }
                        }
                    }) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Color(red: 0.22, green: 0.68, blue: 0.98))
                            .frame(width: 20, height: 20)
                            .background(primaryTextColor.opacity(0.07))
                            .clipShape(Circle())
                    }
                    .buttonStyle(TactileButtonStyle())
                    .help(L10n.createProfileHelp)
                    
                    // Переименовать профиль
                    Button(action: {
                        activeDropdown = nil
                        if let current = profileManager.activeProfile {
                            renameProfileName = current.name
                            isCreatingProfile = false
                            isRenamingProfile.toggle()
                            if isRenamingProfile {
                                DispatchQueue.main.async { isProfileTextFieldFocused = true }
                            }
                        }
                    }) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(primaryTextColor.opacity(0.75))
                            .frame(width: 20, height: 20)
                            .background(primaryTextColor.opacity(0.07))
                            .clipShape(Circle())
                    }
                    .buttonStyle(TactileButtonStyle())
                    .help(L10n.renameProfileHelp)
                    
                    // Удалить профиль
                    Button(action: {
                        activeDropdown = nil
                        let idToDelete = profileManager.activeProfileID
                        if profileManager.deleteProfile(id: idToDelete) {
                            if let next = profileManager.activeProfile {
                                coordinator.applyProfile(next)
                            }
                        }
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(profileManager.profiles.count > 1 ? Color.red.opacity(0.85) : secondaryTextColor.opacity(0.35))
                            .frame(width: 20, height: 20)
                            .background(primaryTextColor.opacity(0.07))
                            .clipShape(Circle())
                    }
                    .buttonStyle(TactileButtonStyle())
                    .disabled(profileManager.profiles.count <= 1)
                    .help(L10n.deleteProfileHelp(profileManager.profiles.count > 1))
                }
                
                // Кастомный выпадающий список профиля под словом «Профиль»
                StyledDropdownTrigger(
                    menuKind: .profile,
                    iconSymbol: "slider.horizontal.3",
                    title: profileManager.activeProfile?.name ?? L10n.defaultProfileName,
                    isOpen: activeDropdown == .profile,
                    isDark: isDark
                ) {
                    withAnimation(.spring(response: 0.14, dampingFraction: 0.84)) {
                        activeDropdown = (activeDropdown == .profile) ? nil : .profile
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(cardBgColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(cardBorderColor, lineWidth: 1)
                    )
            )
            
            // Правая карточка: Крупные минималистичные значки Наушники / Колонки
            HStack(spacing: 5) {
                Button(action: {
                    withAnimation(.spring(response: 0.18, dampingFraction: 0.78)) {
                        coordinator.isSpeakerMode = false
                    }
                }) {
                    MinimalHeadphonesIcon()
                        .frame(width: 26, height: 26)
                        .foregroundColor(!coordinator.isSpeakerMode ? .white : primaryTextColor.opacity(0.50))
                        .frame(width: 52, height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(
                                    !coordinator.isSpeakerMode
                                        ? LinearGradient(colors: [Color(red: 0.18, green: 0.52, blue: 0.98), Color(red: 0.12, green: 0.76, blue: 0.95)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                        : LinearGradient(colors: [Color.clear, Color.clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                        )
                        .shadow(color: !coordinator.isSpeakerMode ? Color.blue.opacity(0.28) : .clear, radius: 4, x: 0, y: 2)
                }
                .buttonStyle(TactileButtonStyle())
                .disabled(!coordinator.isSpatialEnabled || !coordinator.isRunning)
                .help(L10n.modeHeadphonesTitle)
                
                Button(action: {
                    withAnimation(.spring(response: 0.18, dampingFraction: 0.78)) {
                        coordinator.isSpeakerMode = true
                    }
                }) {
                    MinimalSpeakersIcon()
                        .frame(width: 26, height: 26)
                        .foregroundColor(coordinator.isSpeakerMode ? .white : primaryTextColor.opacity(0.50))
                        .frame(width: 52, height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(
                                    coordinator.isSpeakerMode
                                        ? LinearGradient(colors: [Color(red: 0.18, green: 0.52, blue: 0.98), Color(red: 0.12, green: 0.76, blue: 0.95)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                        : LinearGradient(colors: [Color.clear, Color.clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                        )
                        .shadow(color: coordinator.isSpeakerMode ? Color.blue.opacity(0.28) : .clear, radius: 4, x: 0, y: 2)
                }
                .buttonStyle(TactileButtonStyle())
                .disabled(!coordinator.isSpatialEnabled || !coordinator.isRunning)
                .help(L10n.modeSpeakersTitle)
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(cardBgColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(cardBorderColor, lineWidth: 1)
                    )
            )
        }
    }
    
    private static func verifyInstallerSignature(at path: String) -> Bool {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        check.arguments = ["--check-signature", path]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        do {
            try check.run()
            check.waitUntilExit()
            return check.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func submitCreateProfile() {
        let p = profileManager.createProfile(
            name: newProfileName,
            isSpatialEnabled: coordinator.isSpatialEnabled,
            speakerAngleDeg: coordinator.speakerAngleDeg,
            reverbBlend: coordinator.reverbBlend,
            volume: coordinator.volume,
            isSpeakerMode: coordinator.isSpeakerMode,
            physicalSpeakerAngleDeg: coordinator.physicalSpeakerAngleDeg
        )
        coordinator.applyProfile(p)
        isCreatingProfile = false
    }

    private func submitRenameProfile() {
        profileManager.renameProfile(id: profileManager.activeProfileID, newName: renameProfileName)
        isRenamingProfile = false
    }

    // Инлайн-редактор создания / переименования профиля
    private var profileInlineEditorCard: some View {
        HStack(spacing: 6) {
            if isCreatingProfile {
                TextField(L10n.profileNamePlaceholder, text: $newProfileName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($isProfileTextFieldFocused)
                    .onSubmit {
                        submitCreateProfile()
                    }
                
                Button(L10n.createBtn) {
                    submitCreateProfile()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                
                Button(L10n.cancelBtn) {
                    isCreatingProfile = false
                }
                .controlSize(.small)
            } else if isRenamingProfile {
                TextField(L10n.newNamePlaceholder, text: $renameProfileName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($isProfileTextFieldFocused)
                    .onSubmit {
                        submitRenameProfile()
                    }
                
                Button(L10n.saveBtn) {
                    submitRenameProfile()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                
                Button(L10n.cancelBtn) {
                    isRenamingProfile = false
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(cardBgColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(cardBorderColor, lineWidth: 1)
                )
        )
    }
    
    // MARK: - 3. Визуализатор звуковой сцены + капсула переключения 3D / Bypass
    
    private var visualizerCard: some View {
        ZStack(alignment: .top) {
            SoundstageVisualizer(
                angle: coordinator.isSpeakerMode ? coordinator.physicalSpeakerAngleDeg : coordinator.speakerAngleDeg,
                isEnabled: coordinator.isSpatialEnabled && coordinator.isRunning,
                leftLevel: coordinator.leftLevel,
                rightLevel: coordinator.rightLevel,
                listenerLabel: L10n.listenerYou,
                isDark: isDark
            )
            .frame(height: 124)
            
            HStack {
                Button(action: {
                    withAnimation(.spring(response: 0.18, dampingFraction: 0.78)) {
                        coordinator.isSpatialEnabled.toggle()
                    }
                }) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(coordinator.isSpatialEnabled ? Color(red: 0.22, green: 0.78, blue: 0.98) : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(coordinator.isSpatialEnabled ? L10n.spatialSceneOnBadge : L10n.bypassBadge)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(primaryTextColor)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(isDark ? Color.black.opacity(0.50) : Color.white.opacity(0.90))
                            .overlay(
                                Capsule()
                                    .stroke(cardBorderColor, lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(TactileButtonStyle())
                .disabled(!coordinator.isRunning)
                
                Spacer()
                
                let currentDeg = coordinator.isSpeakerMode ? coordinator.physicalSpeakerAngleDeg : coordinator.speakerAngleDeg
                Text("±\(Int(round(currentDeg)))°")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(isDark ? Color(red: 0.35, green: 0.85, blue: 0.98) : Color(red: 0.05, green: 0.45, blue: 0.88))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(isDark ? Color.black.opacity(0.50) : Color.white.opacity(0.90))
                            .overlay(
                                Capsule()
                                    .stroke(cardBorderColor, lineWidth: 1)
                            )
                    )
            }
            .padding(9)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardBgColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(cardBorderColor, lineWidth: 1)
                )
        )
    }
    
    // MARK: - 4. Капсульные ползунки настроек сцены
    
    private var slidersCard: some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(coordinator.isSpeakerMode ? L10n.physicalSpeakerAngleLabel : L10n.stageWidthLabel)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(secondaryTextColor)
                    Spacer()
                    if coordinator.isSpeakerMode {
                        let deg = coordinator.physicalSpeakerAngleDeg
                        let formattedHalf = (abs(deg.rounded() - deg) < 0.05)
                            ? String(format: "±%.0f°", deg)
                            : String(format: "±%.1f°", deg)
                        Text("\(formattedHalf) (\(Int(round(deg * 2.0)))°)")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundColor(isDark ? Color(red: 0.35, green: 0.85, blue: 0.98) : Color(red: 0.05, green: 0.45, blue: 0.88))
                    } else {
                        Text("±\(Int(coordinator.speakerAngleDeg))°")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundColor(isDark ? Color(red: 0.35, green: 0.85, blue: 0.98) : Color(red: 0.05, green: 0.45, blue: 0.88))
                    }
                }
                if coordinator.isSpeakerMode {
                    Slider(value: $coordinator.physicalSpeakerAngleDeg, in: 10.0...35.0, step: 0.5)
                        .tint(Color(red: 0.16, green: 0.75, blue: 0.96))
                        .disabled(!coordinator.isSpatialEnabled || !coordinator.isRunning)
                } else {
                    Slider(value: $coordinator.speakerAngleDeg, in: 15.0...60.0, step: 1.0)
                        .tint(Color(red: 0.16, green: 0.75, blue: 0.96))
                        .disabled(!coordinator.isSpatialEnabled || !coordinator.isRunning)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(cardBgColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke(cardBorderColor, lineWidth: 1)
                    )
            )
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L10n.roomAcousticsLabel)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(secondaryTextColor)
                    Spacer()
                    Text(String(format: "%.1f%%", coordinator.reverbBlend * 100))
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundColor(isDark ? Color(red: 0.38, green: 0.68, blue: 0.98) : Color(red: 0.15, green: 0.40, blue: 0.92))
                }
                Slider(value: $coordinator.reverbBlend, in: 0.0...0.03, step: 0.001)
                    .tint(Color(red: 0.22, green: 0.55, blue: 0.98))
                    .disabled(!coordinator.isSpatialEnabled || !coordinator.isRunning)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(cardBgColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke(cardBorderColor, lineWidth: 1)
                    )
            )
        }
    }
    
    // MARK: - 5. Устройства ввода/вывода (кастомные списки) + Индикаторы уровня L/R
    
    private var devicesAndMetersCard: some View {
        let selectedInDev = coordinator.inputDevices.first(where: { $0.id == coordinator.selectedInputDeviceID }) ?? coordinator.inputDevices.first
        let selectedOutDev = coordinator.outputDevices.first(where: { $0.id == coordinator.selectedOutputDeviceID }) ?? coordinator.outputDevices.first
        
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(L10n.inputLabel)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(secondaryTextColor)
                    .frame(width: 48, alignment: .leading)
                
                StyledDropdownTrigger(
                    menuKind: .inputDevice,
                    iconSymbol: selectedInDev.map { inputDeviceSymbol(for: $0) } ?? "waveform.circle.fill",
                    title: selectedInDev?.name ?? "BlackHole 2ch",
                    isOpen: activeDropdown == .inputDevice,
                    isDark: isDark
                ) {
                    withAnimation(.spring(response: 0.14, dampingFraction: 0.84)) {
                        activeDropdown = (activeDropdown == .inputDevice) ? nil : .inputDevice
                    }
                }
            }
            
            HStack(spacing: 8) {
                Text(L10n.outputLabel)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(secondaryTextColor)
                    .frame(width: 48, alignment: .leading)
                
                StyledDropdownTrigger(
                    menuKind: .outputDevice,
                    iconSymbol: selectedOutDev.map { outputDeviceSymbol(for: $0) } ?? "headphones",
                    title: selectedOutDev?.name ?? L10n.headphonesFallback,
                    isOpen: activeDropdown == .outputDevice,
                    isDark: isDark
                ) {
                    withAnimation(.spring(response: 0.14, dampingFraction: 0.84)) {
                        activeDropdown = (activeDropdown == .outputDevice) ? nil : .outputDevice
                    }
                }
            }
            
            // Звуковые полосы L и R (в единой изумрудно-бирюзово-синей гамме с фоновыми волнами)
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Text("L")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(secondaryTextColor)
                    AudioLevelMeter(level: coordinator.leftLevel, isDark: isDark)
                }
                HStack(spacing: 6) {
                    AudioLevelMeter(level: coordinator.rightLevel, isDark: isDark)
                    Text("R")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(secondaryTextColor)
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardBgColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(cardBorderColor, lineWidth: 1)
                )
        )
    }
    
    // MARK: - 6. Нижняя панель быстрых действий
    
    private var footerCard: some View {
        HStack {
            Button(action: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension"),
                   NSWorkspace.shared.open(url) {
                    return
                }
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Sound.prefPane"))
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .semibold))
                    Text(L10n.soundSettingsHelp)
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundColor(secondaryTextColor)
            }
            .buttonStyle(TactileButtonStyle())
            
            Spacer()
            
            Button(action: {
                coordinator.stopPipeline(restoreSystemAudio: true)
                NSApplication.shared.terminate(nil)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .bold))
                    Text(L10n.quitShortTitle)
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundColor(Color(red: 0.96, green: 0.32, blue: 0.40))
            }
            .buttonStyle(TactileButtonStyle())
            .help(L10n.quitHelp)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(cardBgColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(cardBorderColor, lineWidth: 1)
                )
        )
    }
}

// MARK: - Визуализатор звуковой сцены (с акустическим конусом и концентрическими дугами)

struct SoundstageVisualizer: View {
    let angle: Double
    let isEnabled: Bool
    let leftLevel: Float
    let rightLevel: Float
    let listenerLabel: String
    let isDark: Bool
    
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let centerX = w / 2.0
            let bottomY = h - 20.0
            let reach: CGFloat = 64.0
            let rad = angle * .pi / 180.0
            
            let lx = centerX - reach * sin(CGFloat(rad))
            let rx = centerX + reach * sin(CGFloat(rad))
            let ly = bottomY - reach * cos(CGFloat(rad))
            let ry = bottomY - reach * cos(CGFloat(rad))
            
            ZStack {
                RadialGradient(
                    colors: isEnabled
                        ? [Color(red: 0.14, green: 0.72, blue: 0.96).opacity(isDark ? 0.22 : 0.16), Color.clear]
                        : [Color.clear, Color.clear],
                    center: .bottom,
                    startRadius: 6,
                    endRadius: 110
                )
                
                ForEach([34.0, 64.0], id: \.self) { r in
                    Path { path in
                        path.addArc(
                            center: CGPoint(x: centerX, y: bottomY),
                            radius: CGFloat(r),
                            startAngle: .degrees(200),
                            endAngle: .degrees(340),
                            clockwise: false
                        )
                    }
                    .stroke(isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.07), lineWidth: 1)
                }
                
                if isEnabled {
                    Path { path in
                        path.move(to: CGPoint(x: centerX, y: bottomY))
                        path.addArc(
                            center: CGPoint(x: centerX, y: bottomY),
                            radius: reach,
                            startAngle: .degrees(-90.0 - angle),
                            endAngle: .degrees(-90.0 + angle),
                            clockwise: false
                        )
                        path.closeSubpath()
                    }
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.22, green: 0.78, blue: 0.98).opacity(isDark ? 0.26 : 0.20),
                                Color(red: 0.20, green: 0.50, blue: 0.96).opacity(0.02)
                            ],
                            center: .bottom,
                            startRadius: 4,
                            endRadius: reach
                        )
                    )
                }
                
                Path { path in
                    path.move(to: CGPoint(x: centerX, y: bottomY - 8))
                    path.addLine(to: CGPoint(x: lx, y: ly + 8))
                    path.move(to: CGPoint(x: centerX, y: bottomY - 8))
                    path.addLine(to: CGPoint(x: rx, y: ry + 8))
                }
                .stroke(
                    isEnabled
                        ? Color(red: 0.20, green: 0.74, blue: 0.98).opacity(0.55)
                        : Color.gray.opacity(0.25),
                    style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])
                )
                
                VStack(spacing: 1) {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.16, green: 0.78, blue: 0.98), Color(red: 0.18, green: 0.48, blue: 0.96)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 15, height: 15)
                        .shadow(color: Color.cyan.opacity(0.35), radius: 4, x: 0, y: 1)
                    
                    Text(listenerLabel)
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(isDark ? .white.opacity(0.85) : Color(red: 0.15, green: 0.20, blue: 0.30))
                }
                .position(x: centerX, y: bottomY)
                
                SpeakerNode(label: "L", isActive: isEnabled, level: leftLevel)
                    .position(x: lx, y: ly)
                
                SpeakerNode(label: "R", isActive: isEnabled, level: rightLevel)
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
        ZStack {
            Circle()
                .fill(isActive ? Color(red: 0.22, green: 0.78, blue: 0.98).opacity(0.25) : Color.clear)
                .frame(width: 20 + CGFloat(level * 14), height: 20 + CGFloat(level * 14))
            
            Circle()
                .fill(
                    isActive
                        ? LinearGradient(colors: [Color(red: 0.22, green: 0.80, blue: 0.98), Color(red: 0.18, green: 0.52, blue: 0.96)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        : LinearGradient(colors: [Color.gray.opacity(0.5), Color.gray.opacity(0.4)], startPoint: .top, endPoint: .bottom)
                )
                .frame(width: 19, height: 19)
                .shadow(color: isActive ? Color.cyan.opacity(0.35) : .clear, radius: 4, x: 0, y: 1)
            
            Text(label)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundColor(.white)
        }
    }
}

// MARK: - Звуковые полосы L / R (в фирменной изумрудно-бирюзово-синей палитре без задержки)

struct AudioLevelMeter: View {
    let level: Float
    let isDark: Bool
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.08))
                
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.16, green: 0.84, blue: 0.58),
                                Color(red: 0.20, green: 0.76, blue: 0.96),
                                Color(red: 0.28, green: 0.46, blue: 0.98)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(level))))
            }
        }
        .frame(height: 6)
    }
}
