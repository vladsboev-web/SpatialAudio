import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import Accelerate

/// Параметры одного параметрического биквад-фильтра (RBJ Peaking EQ)
private struct BiquadParam {
    var freq: Double
    var q: Double
    var gainDB: Double
}

/// Состояние биквада Direct Form II Transposed (Double-точность для отсутствия квантования на НЧ 46 Гц)
private struct BiquadFilterState {
    var b0: Double = 1.0
    var b1: Double = 0.0
    var b2: Double = 0.0
    var a1: Double = 0.0
    var a2: Double = 0.0
    var z1: Double = 0.0
    var z2: Double = 0.0

    mutating func updatePeaking(freq: Double, q: Double, gainDB: Double, sampleRate: Double) {
        guard abs(gainDB) > 1e-4, freq > 10.0, freq < sampleRate * 0.48 else {
            b0 = 1.0; b1 = 0.0; b2 = 0.0; a1 = 0.0; a2 = 0.0
            return
        }
        let A = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * Double.pi * freq / sampleRate
        let cosw = cos(w0)
        let alpha = sin(w0) / (2.0 * max(0.1, q))
        let b0Raw = 1.0 + alpha * A
        let b1Raw = -2.0 * cosw
        let b2Raw = 1.0 - alpha * A
        let a0Raw = 1.0 + alpha / A
        let a1Raw = -2.0 * cosw
        let a2Raw = 1.0 - alpha / A
        let invA0 = 1.0 / a0Raw
        b0 = b0Raw * invA0
        b1 = b1Raw * invA0
        b2 = b2Raw * invA0
        a1 = a1Raw * invA0
        a2 = a2Raw * invA0
    }

    mutating func updateHighShelf(freq: Double, q: Double, gainDB: Double, sampleRate: Double) {
        guard abs(gainDB) > 1e-4, freq > 10.0, freq < sampleRate * 0.48 else {
            b0 = 1.0; b1 = 0.0; b2 = 0.0; a1 = 0.0; a2 = 0.0
            return
        }
        let A = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * Double.pi * freq / sampleRate
        let cosw = cos(w0)
        let alpha = sin(w0) / (2.0 * max(0.1, q))
        let twoSqrtAAlpha = 2.0 * sqrt(A) * alpha
        let b0Raw = A * ((A + 1.0) + (A - 1.0) * cosw + twoSqrtAAlpha)
        let b1Raw = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosw)
        let b2Raw = A * ((A + 1.0) + (A - 1.0) * cosw - twoSqrtAAlpha)
        let a0Raw = (A + 1.0) - (A - 1.0) * cosw + twoSqrtAAlpha
        let a1Raw = 2.0 * ((A - 1.0) - (A + 1.0) * cosw)
        let a2Raw = (A + 1.0) - (A - 1.0) * cosw - twoSqrtAAlpha
        let invA0 = 1.0 / a0Raw
        b0 = b0Raw * invA0
        b1 = b1Raw * invA0
        b2 = b2Raw * invA0
        a1 = a1Raw * invA0
        a2 = a2Raw * invA0
    }

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func reset() {
        z1 = 0.0
        z2 = 0.0
    }
}

/// Разводит один стерео-поток из кольцевого буфера на два пути рендера.
/// Все колбэки вызываются в одном IO-потоке AVAudioEngine, поэтому дополнительная синхронизация не нужна.
private final class StereoFeed {
    static let maxFrames = 8192

    let ring: AudioRingBuffer
    /// true — звук идёт прямым путём (bypass), false — через 3D-сцену (наушники) или тракт колонок
    var isBypass: Bool = false
    /// true — режим стерео-колонок (Этап 4.5: без HRTFHQ, с M/S расширением под физический угол и посылом в комнату)
    var isSpeakerMode: Bool = false
    /// Физический полуугол расстановки колонок пользователя (по умолчанию ±22.5°, т.е. ~45° между колонками на 3м)
    var physicalSpeakerAngleDeg: Double = 22.5

    // MARK: - Параметры калибровки наушников и режима колонок
    var sampleRate: Double = 48000.0
    var targetAngleDeg: Double = 30.0
    var targetReverbBlend: Double = 0.01

    // Сглаженные параметры в реальном времени (интерполяция в пространстве (log f, Q, gain) без щелчков)
    private var currentMidParam = BiquadParam(freq: 1620.0, q: 1.10, gainDB: 3.50)
    private var currentReverbPct: Double = 1.0
    private var currentSpeakerSideGainDB: Double = 2.32
    private var currentSpeakerMakeupLinear: Double = pow(10.0, -0.45 / 20.0)
    private var filtersInitialized: Bool = false
    private var lastHeadphoneSR: Double = 0.0
    /// Выравнивание громкости наушников по LUFS с Bypass (Этап 3.8 п. 5.2: preGain = -0.5 dB)
    private static let headphoneMakeupLinear: Double = pow(10.0, -0.50 / 20.0)

    // Состояния фильтров:
    // - Наушники: 1 секция Mid-EQ + по 10 секций L/R (7 полос DF-EQ Уровень Б + 3 полосы Reverb-EQ)
    // - Колонки: 1 секция High-Shelf (> 250 Гц) в Side-канале (бас < 200 Гц остаётся 1:1, моно L+R=2M 100% неизменно)
    private var midFilter = BiquadFilterState()
    private var speakerSideShelfFilter = BiquadFilterState()
    private var dfFiltersL = [BiquadFilterState](repeating: BiquadFilterState(), count: 7)
    private var dfFiltersR = [BiquadFilterState](repeating: BiquadFilterState(), count: 7)
    private var revFiltersL = [BiquadFilterState](repeating: BiquadFilterState(), count: 3)
    private var revFiltersR = [BiquadFilterState](repeating: BiquadFilterState(), count: 3)
    private var speakerRevFiltersL = [BiquadFilterState](repeating: BiquadFilterState(), count: 3)
    private var speakerRevFiltersR = [BiquadFilterState](repeating: BiquadFilterState(), count: 3)
    private var currentSpeakerReverbPct: Double = 1.0
    private var speakerFiltersInitialized: Bool = false
    private var lastSpeakerSR: Double = 0.0
    private var lastActiveBypass: Bool = false
    private var lastActiveSpeakerMode: Bool = false

    // Снимок настроек на текущий цикл рендера (исключает рассинхрон между вызовами left/right/bypass внутри одного цикла)
    private var cycleBypass: Bool = false
    private var cycleSpeakerMode: Bool = false
    private var cycleReverbBlend: Double = 0.01

    // Константы 7-полосного DF-EQ (Кандидат 2, Уровень Б: -7.43 dB @ 12.75 кГц)
    private static let dfBaseBands: [BiquadParam] = [
        BiquadParam(freq: 1230.0,  q: 0.77, gainDB: -0.43),
        BiquadParam(freq: 2260.0,  q: 1.70, gainDB: -1.42),
        BiquadParam(freq: 3530.0,  q: 4.50, gainDB: -0.97),
        BiquadParam(freq: 7310.0,  q: 2.98, gainDB: -4.35),
        BiquadParam(freq: 10340.0, q: 4.50, gainDB: +0.65),
        BiquadParam(freq: 12600.0, q: 2.07, gainDB: -5.60),
        BiquadParam(freq: 12750.0, q: 3.00, gainDB: -1.75)
    ]

    // Опорные узлы Mid-EQ Схема (а) (один колокол с адаптивным расширением Q до 0.68 на 40°–45°)
    private static let midAnchors: [(a: Double, f: Double, q: Double, g: Double)] = [
        (15, 3050, 1.10, 3.20),
        (20, 2650, 1.05, 3.30),
        (25, 1850, 1.05, 3.40),
        (30, 1620, 1.10, 3.50),
        (35, 1520, 1.00, 3.50),
        (40, 1250, 0.72, 3.50),
        (45, 1000, 0.68, 3.60),
        (50,  780, 0.80, 3.70),
        (55,  660, 0.95, 3.80),
        (60,  610, 1.00, 3.80)
    ]

    private let stashL = UnsafeMutablePointer<Float>.allocate(capacity: StereoFeed.maxFrames)
    private let stashR = UnsafeMutablePointer<Float>.allocate(capacity: StereoFeed.maxFrames)
    private var stashFrames: Int = 0
    private var consumedL: Bool = true
    private var consumedR: Bool = true
    private var consumedDirect: Bool = true

    init(ring: AudioRingBuffer) {
        self.ring = ring
        stashL.initialize(repeating: 0, count: StereoFeed.maxFrames)
        stashR.initialize(repeating: 0, count: StereoFeed.maxFrames)
    }

    deinit {
        stashL.deallocate()
        stashR.deallocate()
    }

    private static func targetMidParam(forAngle angleDeg: Double) -> BiquadParam {
        let clamped = max(15.0, min(60.0, angleDeg))
        for i in 0..<(midAnchors.count - 1) {
            let p0 = midAnchors[i]
            let p1 = midAnchors[i + 1]
            if clamped >= p0.a && clamped <= p1.a {
                let t = (clamped - p0.a) / (p1.a - p0.a)
                let s = 0.5 * (1.0 - cos(.pi * t))
                let f = p0.f * pow(p1.f / p0.f, s)
                let q = p0.q + (p1.q - p0.q) * s
                let g = p0.g + (p1.g - p0.g) * s
                return BiquadParam(freq: f, q: q, gainDB: g)
            }
        }
        return BiquadParam(freq: 1620.0, q: 1.10, gainDB: 3.50)
    }

    func resetState() {
        filtersInitialized = false
        speakerFiltersInitialized = false
        lastHeadphoneSR = 0.0
        lastSpeakerSR = 0.0
        stashFrames = 0
        consumedL = true
        consumedR = true
        consumedDirect = true
        clearFilterDelayLines()
    }

    private func clearFilterDelayLines() {
        midFilter.reset()
        speakerSideShelfFilter.reset()
        for i in 0..<7 {
            dfFiltersL[i].reset()
            dfFiltersR[i].reset()
        }
        for i in 0..<3 {
            revFiltersL[i].reset()
            revFiltersR[i].reset()
            speakerRevFiltersL[i].reset()
            speakerRevFiltersR[i].reset()
        }
    }

    /// Поблочная интерполяция в пространстве (log f, Q, gain) и фильтрация с выравниванием громкости по LUFS (-0.5 dB)
    private func applyCalibrationAndLUFSMatch(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let sr = max(44100.0, sampleRate)
        let goalRevPct = max(0.0, min(3.0, cycleReverbBlend * 100.0))
        let goalMid = StereoFeed.targetMidParam(forAngle: targetAngleDeg)
        let g = StereoFeed.headphoneMakeupLinear

        if !filtersInitialized || abs(sr - lastHeadphoneSR) > 0.5 {
            currentMidParam = goalMid
            currentReverbPct = goalRevPct
            updateFilterCoefficients(sr: sr)
            if abs(sr - lastHeadphoneSR) > 0.5 {
                clearFilterDelayLines()
            }
            lastHeadphoneSR = sr
            filtersInitialized = true
        }

        // Разбиваем буфер на подблоки по 64 сэмпла (~1.3 мс) для абсолютно бесшовной интерполяции параметров
        let subBlock = 64
        var offset = 0
        while offset < frames {
            let count = min(subBlock, frames - offset)
            let alpha = 0.22 // Плавная экспоненциальная сходимость за ~15–20 мс без щелчков

            let needUpdate =
                abs(currentMidParam.freq - goalMid.freq) > 0.05 ||
                abs(currentMidParam.q - goalMid.q) > 0.001 ||
                abs(currentMidParam.gainDB - goalMid.gainDB) > 0.002 ||
                abs(currentReverbPct - goalRevPct) > 0.001

            if needUpdate {
                currentMidParam.freq = currentMidParam.freq * pow(goalMid.freq / max(20.0, currentMidParam.freq), alpha)
                currentMidParam.q += (goalMid.q - currentMidParam.q) * alpha
                currentMidParam.gainDB += (goalMid.gainDB - currentMidParam.gainDB) * alpha
                currentReverbPct += (goalRevPct - currentReverbPct) * alpha
                updateFilterCoefficients(sr: sr)
            }

            let revActive = currentReverbPct > 1e-4

            for i in 0..<count {
                let idx = offset + i
                var l = Double(left[idx]) * g
                var r = Double(right[idx]) * g

                let m = midFilter.process(0.5 * (l + r))
                let s = 0.5 * (l - r)
                l = m + s
                r = m - s

                for b in 0..<7 {
                    l = dfFiltersL[b].process(l)
                    r = dfFiltersR[b].process(r)
                }
                if revActive {
                    for b in 0..<3 {
                        l = revFiltersL[b].process(l)
                        r = revFiltersR[b].process(r)
                    }
                }

                left[idx] = Float(l)
                right[idx] = Float(r)
            }

            offset += count
        }
    }

    private func updateFilterCoefficients(sr: Double) {
        midFilter.updatePeaking(freq: currentMidParam.freq, q: currentMidParam.q, gainDB: currentMidParam.gainDB, sampleRate: sr)

        for b in 0..<7 {
            let p = StereoFeed.dfBaseBands[b]
            dfFiltersL[b].updatePeaking(freq: p.freq, q: p.q, gainDB: p.gainDB, sampleRate: sr)
            dfFiltersR[b].updatePeaking(freq: p.freq, q: p.q, gainDB: p.gainDB, sampleRate: sr)
        }

        let pct = currentReverbPct
        let g46  = (pct > 0.001) ? (+2.45 * (1.0 - exp(-pct / 0.55))) : 0.0
        let g82  = (pct > 0.001) ? (-0.28 * pct) : 0.0
        let g235 = (pct > 0.001) ? (-0.45 * pow(pct, 0.72)) : 0.0

        revFiltersL[0].updatePeaking(freq: 46.0,  q: 1.90, gainDB: g46,  sampleRate: sr)
        revFiltersR[0].updatePeaking(freq: 46.0,  q: 1.90, gainDB: g46,  sampleRate: sr)
        revFiltersL[1].updatePeaking(freq: 82.0,  q: 2.80, gainDB: g82,  sampleRate: sr)
        revFiltersR[1].updatePeaking(freq: 82.0,  q: 2.80, gainDB: g82,  sampleRate: sr)
        revFiltersL[2].updatePeaking(freq: 235.0, q: 0.90, gainDB: g235, sampleRate: sr)
        revFiltersR[2].updatePeaking(freq: 235.0, q: 0.90, gainDB: g235, sampleRate: sr)
    }

    /// Поблочная обработка в режиме колонок (Этап 4.5: без HRTFHQ, High-Shelf M/S расширение > 250 Гц по закону Бауэра sin(30°)/sin(θ_phys),
    /// 100% сохранение моно L+R = 2M и баса ниже 200 Гц, компенсация НЧ-интерференции .smallRoom и выравнивание громкости по LUFS)
    private func applySpeakerModeShuffler(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let sr = max(44100.0, sampleRate)
        let physRad = max(10.0, min(60.0, physicalSpeakerAngleDeg)) * .pi / 180.0
        // Раскрываем реальный угол колонок (±22.5° по умолчанию) до эталонного стерео-треугольника ±30° (sin 30° = 0.5)
        let ratio = 0.5 / max(0.15, sin(physRad))
        // Ограничиваем подъём Side диапазоном [0.0 ... +3.5 dB], чтобы при широкой расстановке (> ±30°) не сужать сцену,
        // а при узкой расстановке не создавать избыточной противофазы
        let rawSideDB = 20.0 * log10(max(1.0, ratio))
        let goalSideDB = max(0.0, min(3.5, rawSideDB))
        // Выравнивание громкости по LUFS при изменении энергии Side (в типичном стерео ~35% энергии в Side выше 250 Гц):
        let sidePowerLinear = pow(10.0, goalSideDB / 10.0)
        let estLoudnessChangeDB = 10.0 * log10(0.65 + 0.35 * sidePowerLinear)
        let goalSpeakerMakeup = pow(10.0, -estLoudnessChangeDB / 20.0)
        let goalRevPct = max(0.0, min(3.0, cycleReverbBlend * 100.0))

        if !speakerFiltersInitialized || abs(sr - lastSpeakerSR) > 0.5 {
            currentSpeakerSideGainDB = goalSideDB
            currentSpeakerMakeupLinear = goalSpeakerMakeup
            currentSpeakerReverbPct = goalRevPct
            speakerSideShelfFilter.updateHighShelf(freq: 250.0, q: 0.707, gainDB: currentSpeakerSideGainDB, sampleRate: sr)
            updateSpeakerReverbFilterCoefficients(sr: sr)
            if abs(sr - lastSpeakerSR) > 0.5 {
                clearFilterDelayLines()
            }
            lastSpeakerSR = sr
            speakerFiltersInitialized = true
        }

        let subBlock = 64
        var offset = 0
        while offset < frames {
            let count = min(subBlock, frames - offset)
            let alpha = 0.22
            if abs(currentSpeakerSideGainDB - goalSideDB) > 0.002 {
                currentSpeakerSideGainDB += (goalSideDB - currentSpeakerSideGainDB) * alpha
                speakerSideShelfFilter.updateHighShelf(freq: 250.0, q: 0.707, gainDB: currentSpeakerSideGainDB, sampleRate: sr)
            }
            if abs(currentSpeakerReverbPct - goalRevPct) > 0.001 {
                currentSpeakerReverbPct += (goalRevPct - currentSpeakerReverbPct) * alpha
                updateSpeakerReverbFilterCoefficients(sr: sr)
            }
            let startMakeup = currentSpeakerMakeupLinear
            currentSpeakerMakeupLinear += (goalSpeakerMakeup - currentSpeakerMakeupLinear) * alpha
            let endMakeup = currentSpeakerMakeupLinear
            let invCount = 1.0 / Double(max(1, count))
            let shelfActive = abs(currentSpeakerSideGainDB) > 1e-4
            let revActive = currentSpeakerReverbPct > 1e-4

            for i in 0..<count {
                let idx = offset + i
                let frac = Double(i + 1) * invCount
                let g = startMakeup + (endMakeup - startMakeup) * frac
                var l = Double(left[idx]) * g
                var r = Double(right[idx]) * g
                if shelfActive {
                    let m = 0.5 * (l + r)
                    let s = speakerSideShelfFilter.process(0.5 * (l - r))
                    l = m + s
                    r = m - s
                }
                if revActive {
                    for b in 0..<3 {
                        l = speakerRevFiltersL[b].process(l)
                        r = speakerRevFiltersR[b].process(r)
                    }
                }
                left[idx] = Float(l)
                right[idx] = Float(r)
            }
            offset += count
        }
    }

    private func updateSpeakerReverbFilterCoefficients(sr: Double) {
        let pct = currentSpeakerReverbPct
        let g46  = (pct > 0.001) ? (+1.35 * (1.0 - exp(-pct / 0.55))) : 0.0
        let g82  = (pct > 0.001) ? (-0.22 * pct) : 0.0
        let g235 = (pct > 0.001) ? (-0.34 * pow(pct, 0.72)) : 0.0

        speakerRevFiltersL[0].updatePeaking(freq: 46.0,  q: 1.90, gainDB: g46,  sampleRate: sr)
        speakerRevFiltersR[0].updatePeaking(freq: 46.0,  q: 1.90, gainDB: g46,  sampleRate: sr)
        speakerRevFiltersL[1].updatePeaking(freq: 82.0,  q: 2.80, gainDB: g82,  sampleRate: sr)
        speakerRevFiltersR[1].updatePeaking(freq: 82.0,  q: 2.80, gainDB: g82,  sampleRate: sr)
        speakerRevFiltersL[2].updatePeaking(freq: 235.0, q: 0.90, gainDB: g235, sampleRate: sr)
        speakerRevFiltersR[2].updatePeaking(freq: 235.0, q: 0.90, gainDB: g235, sampleRate: sr)
    }

    private func populateStashIfNeeded(frames: Int, needL: Bool, needR: Bool, needDirect: Bool) {
        let alreadyConsumed = (needL && consumedL) || (needR && consumedR) || (needDirect && consumedDirect)
        if alreadyConsumed || frames != stashFrames {
            // Фиксируем единый снимок настроек на весь текущий цикл рендера (для L, R и Direct)
            let curBypass = isBypass
            let curSpeaker = isSpeakerMode
            let curRev = targetReverbBlend
            if curBypass != lastActiveBypass || curSpeaker != lastActiveSpeakerMode {
                clearFilterDelayLines()
                lastActiveBypass = curBypass
                lastActiveSpeakerMode = curSpeaker
            }
            cycleBypass = curBypass
            cycleSpeakerMode = curSpeaker
            cycleReverbBlend = curRev

            ring.read(left: stashL, right: stashR, count: frames)
            if !cycleBypass {
                if cycleSpeakerMode {
                    applySpeakerModeShuffler(left: stashL, right: stashR, frames: frames)
                } else {
                    applyCalibrationAndLUFSMatch(left: stashL, right: stashR, frames: frames)
                }
            }
            stashFrames = frames
            consumedL = false
            consumedR = false
            consumedDirect = false
        }
    }

    /// Моно-канал для 3D-источника (в режиме наушников — основной сигнал + реверб, в режиме колонок — только посыл в реверберацию комнаты).
    func fetchMono(channel: Int, into dst: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames <= StereoFeed.maxFrames else {
            vDSP_vclr(dst, 1, vDSP_Length(frames))
            return
        }
        populateStashIfNeeded(frames: frames, needL: channel == 0, needR: channel != 0, needDirect: false)
        if channel == 0 {
            consumedL = true
        } else {
            consumedR = true
        }
        guard !cycleBypass else {
            vDSP_vclr(dst, 1, vDSP_Length(frames))
            return
        }
        // В режиме колонок при reverbBlend == 0 3D-источники вообще не нужны (прямой звук идёт через fetchStereo)
        if cycleSpeakerMode && cycleReverbBlend <= 0.0001 {
            vDSP_vclr(dst, 1, vDSP_Length(frames))
            return
        }
        // В режиме колонок leftNode/rightNode работают с reverbBlend = 1.0 (100% wet),
        // поэтому масштабируем посыл по закону равной мощности sqrt(reverbBlend) * 0.65 (на 35% деликатнее наушников с учётом реальной комнаты)
        let clampedRev = min(0.03, max(0.0, cycleReverbBlend))
        let sendScale: Float = cycleSpeakerMode ? Float(sqrt(clampedRev) * 0.65) : 1.0
        let src = (channel == 0) ? stashL : stashR
        if abs(sendScale - 1.0) < 1e-5 {
            dst.update(from: src, count: frames)
        } else if sendScale <= 1e-6 {
            vDSP_vclr(dst, 1, vDSP_Length(frames))
        } else {
            var s = sendScale
            vDSP_vsmul(src, 1, &s, dst, 1, vDSP_Length(frames))
        }
    }

    /// Прямой стерео-путь: активен в режиме Bypass (чистый 1:1) И в режиме Колонок (Этап 4.5: M/S расширение без HRTFHQ).
    func fetchStereo(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames <= StereoFeed.maxFrames else {
            vDSP_vclr(left, 1, vDSP_Length(frames))
            vDSP_vclr(right, 1, vDSP_Length(frames))
            return
        }
        populateStashIfNeeded(frames: frames, needL: false, needR: false, needDirect: true)
        consumedDirect = true
        guard cycleBypass || cycleSpeakerMode else {
            vDSP_vclr(left, 1, vDSP_Length(frames))
            vDSP_vclr(right, 1, vDSP_Length(frames))
            return
        }
        left.update(from: stashL, count: frames)
        right.update(from: stashR, count: frames)
    }
}

public final class SpatialEngine {
    private var engine = AVAudioEngine()
    public var currentEngine: AVAudioEngine { engine }
    private var environment = AVAudioEnvironmentNode()
    private var limiterNode: AVAudioUnitEffect?
    
    private var leftSourceNode: AVAudioSourceNode?
    private var rightSourceNode: AVAudioSourceNode?
    private var bypassSourceNode: AVAudioSourceNode?
    
    private let feed: StereoFeed
    
    public private(set) var isRunning: Bool = false
    public private(set) var sampleRate: Double = 44100.0
    private var currentOutputDeviceID: AudioDeviceID?
    
    public private(set) var leftLevel: Float = 0.0
    public private(set) var rightLevel: Float = 0.0
    
    // MARK: - Настройки сцены
    public var isSpatialEnabled: Bool = true {
        didSet {
            guard isSpatialEnabled != oldValue else { return }
            feed.isBypass = !isSpatialEnabled
            updateReverb()
        }
    }
    
    public var speakerAngleDeg: Float = 30.0 { // 15° ... 60°
        didSet {
            guard abs(speakerAngleDeg - oldValue) > 0.001 else { return }
            feed.targetAngleDeg = Double(speakerAngleDeg)
            updatePositionsOnly()
        }
    }
    
    public private(set) var distance: Float = 1.0 // Фиксированная оптимальная дистанция 1.0м
    
    public var reverbBlend: Float = 0.01 { // 0.0 ... 0.03 (акустика помещения)
        didSet {
            guard abs(reverbBlend - oldValue) > 0.00001 else { return }
            feed.targetReverbBlend = Double(reverbBlend)
            updateReverb()
        }
    }
    
    public var volume: Float = 1.0 {
        didSet {
            guard abs(volume - oldValue) > 0.0001 else { return }
            updateVolume()
        }
    }

    // MARK: - Настройки режима колонок (Этап 4.5)
    public var isSpeakerMode: Bool = false {
        didSet {
            guard isSpeakerMode != oldValue else { return }
            feed.isSpeakerMode = isSpeakerMode
            updateReverb()
        }
    }

    /// Физический полуугол расстановки колонок пользователя (по умолчанию ±22.5°, т.е. ~45° между колонками на 3м)
    public var physicalSpeakerAngleDeg: Float = 22.5 {
        didSet {
            guard abs(physicalSpeakerAngleDeg - oldValue) > 0.05 else { return }
            feed.physicalSpeakerAngleDeg = Double(physicalSpeakerAngleDeg)
        }
    }
    
    /// Выравнивание громкости по LUFS (-0.5 dB для наушников) выполняется внутри StereoFeed,
    /// поэтому на самом PeakLimiter стоит 0.0 dB (чистый предохранитель пиков).
    private let hrtfCompensationDB: Float = 0.0
    
    private func updateVolume() {
        // Главный микшер — общий для обоих путей; при volume = 1.0 это бит-в-бит прохождение
        engine.mainMixerNode.outputVolume = volume
    }
    
    private func updateReverb() {
        guard let left = leftSourceNode, let right = rightSourceNode else { return }
        if !isSpatialEnabled {
            left.reverbBlend = 0.0
            right.reverbBlend = 0.0
        } else if isSpeakerMode {
            // В режиме колонок (Этап 4.5): прямой сигнал идёт через bypassSourceNode (с M/S shuffler без HRTFHQ),
            // а leftSourceNode / rightSourceNode подают только чистый хвост отражений .smallRoom (100% wet)
            left.reverbBlend = 1.0
            right.reverbBlend = 1.0
        } else {
            // В режиме наушников: от 0.0 (сухой) до 0.03 (естественная комната)
            let blendVal = min(1.0, max(0.0, reverbBlend))
            left.reverbBlend = blendVal
            right.reverbBlend = blendVal
        }
    }

    /// Быстрое обновление только 3D-координат источников при движении ползунка угла
    /// (без повторного назначения renderingAlgorithm, reverbBlend и outputVolume)
    private func updatePositionsOnly() {
        guard let left = leftSourceNode, let right = rightSourceNode else { return }
        let rad = speakerAngleDeg * .pi / 180.0
        let x = distance * sin(rad)
        let z = -distance * cos(rad)
        left.position = AVAudio3DPoint(x: -x, y: 0.0, z: z)
        right.position = AVAudio3DPoint(x: x, y: 0.0, z: z)
    }
    
    public init(ringBuffer: AudioRingBuffer) {
        self.feed = StereoFeed(ring: ringBuffer)
    }
    
    deinit {
        teardownCurrentGraph()
    }
    
    private func teardownCurrentGraph() {
        stop()
        engine.stop()
        for node in [leftSourceNode, rightSourceNode, bypassSourceNode] {
            if let node = node, node.engine != nil { engine.detach(node) }
        }
        leftSourceNode = nil
        rightSourceNode = nil
        bypassSourceNode = nil
        if let lim = limiterNode {
            if lim.engine != nil { engine.detach(lim) }
            limiterNode = nil
        }
        if environment.engine != nil {
            engine.detach(environment)
        }
        engine.reset()
    }
    
    /// Полный синхронный сброс графа и пересоздание AVAudioEngine без гонки потоков в CoreAudio HAL
    public func resetEngine() {
        teardownCurrentGraph()
        self.engine = AVAudioEngine()
        self.environment = AVAudioEnvironmentNode()
    }
    
    private func configureLimiter(_ limiter: AVAudioUnitEffect) {
        let au = limiter.audioUnit
        // Более плавное восстановление — меньше искажений на басу и «пампинга»
        AudioUnitSetParameter(au, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.007, 0)
        AudioUnitSetParameter(au, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.05, 0)
        AudioUnitSetParameter(au, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, hrtfCompensationDB, 0)
    }
    
    public func setup(outputDeviceID: AudioDeviceID, sampleRate: Double = 44100.0) -> Bool {
        resetEngine()
        
        self.currentOutputDeviceID = outputDeviceID
        
        // 1. Привязываем выход AVAudioEngine к выбранному устройству вывода (строго один раз)
        var deviceAssigned = false
        do {
            try engine.outputNode.auAudioUnit.setDeviceID(outputDeviceID)
            deviceAssigned = true
        } catch {
            print("[SpatialEngine] auAudioUnit.setDeviceID предупреждение: \(error)")
        }
        
        if !deviceAssigned, let outputUnit = engine.outputNode.audioUnit {
            var devID = outputDeviceID
            let status = AudioUnitSetProperty(
                outputUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status == noErr {
                deviceAssigned = true
            } else {
                print("[SpatialEngine] Ошибка привязки устройства \(outputDeviceID): \(status)")
                return false
            }
        }
        
        let hwFormat = engine.outputNode.outputFormat(forBus: 0)
        guard hwFormat.channelCount > 0 else {
            print("[SpatialEngine] Выходной поток устройства \(outputDeviceID) ещё не готов (0 каналов)")
            return false
        }
        let actualRate = hwFormat.sampleRate > 0 ? hwFormat.sampleRate : sampleRate
        self.sampleRate = actualRate
        self.feed.sampleRate = actualRate
        self.feed.targetAngleDeg = Double(speakerAngleDeg)
        self.feed.targetReverbBlend = Double(reverbBlend)
        self.feed.isSpeakerMode = isSpeakerMode
        self.feed.physicalSpeakerAngleDeg = Double(physicalSpeakerAngleDeg)
        self.feed.resetState()
        
        engine.attach(environment)
        
        // Отключаем физическое затухание расстояния:
        // Дистанция колонок меняет геометрию сцены, задержку и акустику, но уровень громкости не затухает!
        environment.distanceAttenuationParameters.rolloffFactor = 0.0
        
        // 2. Системный Peak Limiter от Apple — только для 3D-цепочки (страховка после +4 dB компенсации HRTF)
        let limiterDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let limiter = AVAudioUnitEffect(audioComponentDescription: limiterDesc)
        self.limiterNode = limiter
        engine.attach(limiter)
        configureLimiter(limiter)
        
        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: actualRate, channels: 1),
              let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: actualRate, channels: 2) else {
            print("[SpatialEngine] Ошибка создания аудиоформатов")
            return false
        }
        
        let feed = self.feed
        
        // 3. Левый виртуальный источник (3D)
        let leftNode = AVAudioSourceNode(format: monoFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let data = abl[0].mData else { return noErr }
            feed.fetchMono(channel: 0, into: data.assumingMemoryBound(to: Float.self), frames: Int(frameCount))
            return noErr
        }
        
        // 4. Правый виртуальный источник (3D)
        let rightNode = AVAudioSourceNode(format: monoFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let data = abl[0].mData else { return noErr }
            feed.fetchMono(channel: 1, into: data.assumingMemoryBound(to: Float.self), frames: Int(frameCount))
            return noErr
        }
        
        // 5. Прямой стерео-источник (Bypass): мимо 3D-сцены и лимитера, единичное усиление
        let bypassNode = AVAudioSourceNode(format: stereoFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count >= 2,
                  let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            feed.fetchStereo(left: l, right: r, frames: Int(frameCount))
            return noErr
        }
        
        self.leftSourceNode = leftNode
        self.rightSourceNode = rightNode
        self.bypassSourceNode = bypassNode
        
        engine.attach(leftNode)
        engine.attach(rightNode)
        engine.attach(bypassNode)
        
        // Цепочки обработки:
        //   3D:     L/R (моно) -> Окружение (HRTF) -> Peak Limiter (+4 dB pre-gain) -> Главный микшер -> Выход
        //   Bypass: Стерео -----------------------------------------------------> Главный микшер -> Выход
        engine.connect(leftNode, to: environment, format: monoFormat)
        engine.connect(rightNode, to: environment, format: monoFormat)
        engine.connect(environment, to: limiter, format: stereoFormat)
        engine.connect(limiter, to: engine.mainMixerNode, format: stereoFormat)
        engine.connect(bypassNode, to: engine.mainMixerNode, format: stereoFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: stereoFormat)
        
        // 6. Акустика комнаты (натуральная комната прослушивания)
        environment.reverbParameters.enable = true
        environment.reverbParameters.loadFactoryReverbPreset(.smallRoom)
        environment.reverbParameters.level = 0.0
        
        // 7. Позиция слушателя
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)
        
        updateAlgorithmAndPositions()
        
        return true
    }
    
    public func updateAlgorithmAndPositions() {
        // Переключение пути рендера (атомарно для IO-потока: читается один Bool в начале колбэка)
        feed.isBypass = !isSpatialEnabled
        
        guard let left = leftSourceNode, let right = rightSourceNode else { return }
        
        // Настоящий Apple HRTFHQ алгоритм (в режиме Bypass 3D-источники просто получают тишину)
        left.renderingAlgorithm = .HRTFHQ
        right.renderingAlgorithm = .HRTFHQ
        
        let rad = speakerAngleDeg * .pi / 180.0
        let x = distance * sin(rad)
        let z = -distance * cos(rad)
        
        left.position = AVAudio3DPoint(x: -x, y: 0.0, z: z)
        right.position = AVAudio3DPoint(x: x, y: 0.0, z: z)
        
        updateReverb()
        updateVolume()
    }
    
    public func start() -> Bool {
        guard !isRunning else { return true }
        do {
            try engine.start()
            isRunning = true
            return true
        } catch {
            print("[SpatialEngine] Ошибка запуска AVAudioEngine: \(error)")
            return false
        }
    }
    
    public func stop() {
        guard isRunning else { return }
        engine.stop()
        feed.resetState()
        isRunning = false
    }
}
