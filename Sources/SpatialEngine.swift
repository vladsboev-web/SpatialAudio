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

    mutating func updateHighPass(freq: Double, q: Double, sampleRate: Double) {
        guard freq > 10.0, freq < sampleRate * 0.48 else {
            b0 = 1.0; b1 = 0.0; b2 = 0.0; a1 = 0.0; a2 = 0.0
            return
        }
        let w0 = 2.0 * Double.pi * freq / sampleRate
        let cosw = cos(w0)
        let alpha = sin(w0) / (2.0 * max(0.1, q))
        let b0Raw = 0.5 * (1.0 + cosw)
        let b1Raw = -(1.0 + cosw)
        let b2Raw = 0.5 * (1.0 + cosw)
        let a0Raw = 1.0 + alpha
        let a1Raw = -2.0 * cosw
        let a2Raw = 1.0 - alpha
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
    var targetEffectMix: Double = 1.0
    var dryDelaySamples: Int = 5

    // Сглаженные параметры в реальном времени (интерполяция без щелчков)
    private var currentMidGainsDB = [Double](repeating: 0.0, count: 5)
    private var goalMidGainsDB = [Double](repeating: 0.0, count: 5)
    private var currentEffectMix: Double = 1.0
    private var mixInitialized: Bool = false
    private var currentERMasterGain: Double = 0.0
    private var currentERAngleNorm: Double = (30.0 - 15.0) / 45.0
    private var erInitialized: Bool = false
    private var lastERSR: Double = 0.0
    private var currentSpeakerSideGainDB: Double = 2.17
    private var currentSpeakerMakeupLinear: Double = pow(10.0, -0.21 / 20.0)
    private var filtersInitialized: Bool = false
    private var lastHeadphoneSR: Double = 0.0
    /// Выравнивание громкости наушников по LUFS с Bypass (+0.60 dB)
    private static let headphoneMakeupLinear: Double = pow(10.0, 0.60 / 20.0)

    // Константы полосового шаффлера Бауэра в режиме колонок (Этап 6: подъём Side в полосе 240–1750 Гц без ВЧ/сибилянтов и без мёртвых зон 10°…35°)
    private static let speakerShufflerLowFreq: Double = 240.0
    private static let speakerShufflerHighFreq: Double = 1750.0
    private static let speakerShufflerQ: Double = 0.707
    private static let speakerShufflerMaxDB: Double = 4.20
    private static let speakerShufflerKnee: Double = 0.68
    private static let speakerSinRef35: Double = sin(35.0 * .pi / 180.0)
    private static let speakerSideLoudnessWeight: Double = 0.0788

    // Состояния фильтров:
    // - Наушники: 8 постоянных полос DF-EQ на L/R + 5 адаптивных полос Mid (560–2400 Гц)
    // - Колонки: 2 каскадные секции High-Shelf в Side-канале (240 Гц +G / 1750 Гц -G, моно L+R=2M 100% неизменно, ВЧ = 0 dB)
    private var midFilters = [BiquadFilterState](repeating: BiquadFilterState(), count: 5)
    private var dfFiltersL = [BiquadFilterState](repeating: BiquadFilterState(), count: 8)
    private var dfFiltersR = [BiquadFilterState](repeating: BiquadFilterState(), count: 8)
    private var speakerSideLowShelfFilter = BiquadFilterState()
    private var speakerSideHighShelfFilter = BiquadFilterState()
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

    // Блок чистых ранних отражений (Early Reflections) для режима наушников
    private static let erBufSize = 8192
    private static let erBufMask = erBufSize - 1
    private let erEarlyBufL = UnsafeMutablePointer<Float>.allocate(capacity: StereoFeed.erBufSize)
    private let erEarlyBufR = UnsafeMutablePointer<Float>.allocate(capacity: StereoFeed.erBufSize)
    private let erLateBufL = UnsafeMutablePointer<Float>.allocate(capacity: StereoFeed.erBufSize)
    private let erLateBufR = UnsafeMutablePointer<Float>.allocate(capacity: StereoFeed.erBufSize)
    private var erWritePos: Int = 0
    private var erHpf1L = BiquadFilterState()
    private var erHpf2L = BiquadFilterState()
    private var erHpf1R = BiquadFilterState()
    private var erHpf2R = BiquadFilterState()
    private var erLpfEarlyStateL: Double = 0.0
    private var erLpfEarlyStateR: Double = 0.0
    private var erLpfLateStateL: Double = 0.0
    private var erLpfLateStateR: Double = 0.0
    private var erLpfEarlyAlpha: Double = 0.52
    private var erLpfLateAlpha: Double = 0.36

    // 8 постоянных полос DF-EQ (одинаковы на L и R на всех углах)
    private static let dfBaseBands: [BiquadParam] = [
        BiquadParam(freq:   800.0, q: 2.00, gainDB: -1.22),
        BiquadParam(freq:  1250.0, q: 2.20, gainDB: +1.90),
        BiquadParam(freq:  2150.0, q: 1.80, gainDB: -2.74),
        BiquadParam(freq:  3150.0, q: 2.40, gainDB: -0.78),
        BiquadParam(freq:  4050.0, q: 2.40, gainDB: -2.36),
        BiquadParam(freq:  6300.0, q: 2.50, gainDB: -1.55),
        BiquadParam(freq:  9500.0, q: 2.20, gainDB: +1.48),
        BiquadParam(freq: 12650.0, q: 2.50, gainDB: -8.50)
    ]

    // 5 адаптивных полос строго в Mid (560–2400 Гц, 19 углов 15.0°…60.0°, шаг 2.5°)
    private static let midTemplate: [(freq: Double, q: Double)] = [
        (560.0, 1.50), (880.0, 1.70), (1280.0, 1.90), (1620.0, 2.10), (2400.0, 1.80)
    ]

    private static let midGainsDB: [[Double]] = [
        [-1.88, -0.20, -0.55, -0.59, +2.67], // 15.0°
        [-1.80, +0.26, -1.01, +0.76, +3.08], // 17.5°
        [-1.71, +0.73, -1.43, +2.13, +3.28], // 20.0°
        [-1.60, +1.26, -1.81, +3.41, +3.09], // 22.5°
        [-1.45, +1.81, -2.06, +4.40, +2.45], // 25.0°
        [-1.26, +2.35, -2.17, +5.01, +1.45], // 27.5°
        [-1.01, +2.86, -2.18, +5.20, +0.27], // 30.0°
        [-0.70, +3.30, -2.16, +5.20, -0.84], // 32.5°
        [-0.34, +3.63, -2.11, +5.20, -1.68], // 35.0°
        [+0.04, +3.87, -2.03, +5.20, -2.13], // 37.5°
        [+0.43, +4.04, -1.99, +5.01, -2.20], // 40.0°
        [+0.83, +4.16, -2.04, +4.72, -2.20], // 42.5°
        [+1.27, +4.20, -2.12, +4.34, -2.20], // 45.0°
        [+1.75, +4.16, -2.17, +3.91, -2.20], // 47.5°
        [+2.27, +4.02, -2.20, +3.46, -2.19], // 50.0°
        [+2.79, +3.80, -2.20, +2.99, -1.97], // 52.5°
        [+3.29, +3.52, -2.20, +2.56, -1.57], // 55.0°
        [+3.76, +3.20, -2.20, +2.16, -1.04], // 57.5°
        [+4.20, +2.85, -2.20, +1.75, -0.45]  // 60.0°
    ]

    private let rawStashL = UnsafeMutablePointer<Float>.allocate(capacity: StereoFeed.maxFrames)
    private let rawStashR = UnsafeMutablePointer<Float>.allocate(capacity: StereoFeed.maxFrames)
    private let stashL = UnsafeMutablePointer<Float>.allocate(capacity: StereoFeed.maxFrames)
    private let stashR = UnsafeMutablePointer<Float>.allocate(capacity: StereoFeed.maxFrames)
    private let dryStashL = UnsafeMutablePointer<Float>.allocate(capacity: StereoFeed.maxFrames)
    private let dryStashR = UnsafeMutablePointer<Float>.allocate(capacity: StereoFeed.maxFrames)

    private static let dryDelayBufSize = 128
    private static let dryDelayBufMask = dryDelayBufSize - 1
    private var dryDelayBufL = [Float](repeating: 0.0, count: StereoFeed.dryDelayBufSize)
    private var dryDelayBufR = [Float](repeating: 0.0, count: StereoFeed.dryDelayBufSize)
    private var dryDelayWritePos: Int = 0

    private var stashFrames: Int = 0
    private var consumedL: Bool = true
    private var consumedR: Bool = true
    private var consumedDirect: Bool = true
    private var consumedDry: Bool = true

    init(ring: AudioRingBuffer) {
        self.ring = ring
        rawStashL.initialize(repeating: 0, count: StereoFeed.maxFrames)
        rawStashR.initialize(repeating: 0, count: StereoFeed.maxFrames)
        stashL.initialize(repeating: 0, count: StereoFeed.maxFrames)
        stashR.initialize(repeating: 0, count: StereoFeed.maxFrames)
        dryStashL.initialize(repeating: 0, count: StereoFeed.maxFrames)
        dryStashR.initialize(repeating: 0, count: StereoFeed.maxFrames)
        erEarlyBufL.initialize(repeating: 0, count: StereoFeed.erBufSize)
        erEarlyBufR.initialize(repeating: 0, count: StereoFeed.erBufSize)
        erLateBufL.initialize(repeating: 0, count: StereoFeed.erBufSize)
        erLateBufR.initialize(repeating: 0, count: StereoFeed.erBufSize)
    }

    deinit {
        rawStashL.deallocate()
        rawStashR.deallocate()
        stashL.deallocate()
        stashR.deallocate()
        dryStashL.deallocate()
        dryStashR.deallocate()
        erEarlyBufL.deallocate()
        erEarlyBufR.deallocate()
        erLateBufL.deallocate()
        erLateBufR.deallocate()
    }

    private func updateGoalMidGains(forAngle angleDeg: Double) {
        let clamped = max(15.0, min(60.0, angleDeg))
        let pos = (clamped - 15.0) / 2.5
        let idx0 = min(17, max(0, Int(floor(pos))))
        let idx1 = idx0 + 1
        let t = max(0.0, min(1.0, pos - Double(idx0)))
        let s = 0.5 * (1.0 - cos(.pi * t))

        let m0 = StereoFeed.midGainsDB[idx0]
        let m1 = StereoFeed.midGainsDB[idx1]
        for b in 0..<5 {
            goalMidGainsDB[b] = m0[b] + (m1[b] - m0[b]) * s
        }
    }

    func resetState() {
        filtersInitialized = false
        mixInitialized = false
        erInitialized = false
        speakerFiltersInitialized = false
        lastHeadphoneSR = 0.0
        lastERSR = 0.0
        lastSpeakerSR = 0.0
        stashFrames = 0
        consumedL = true
        consumedR = true
        consumedDirect = true
        consumedDry = true
        clearFilterDelayLines()
    }

    private func clearFilterDelayLines() {
        for i in 0..<5 {
            midFilters[i].reset()
        }
        for i in 0..<8 {
            dfFiltersL[i].reset()
            dfFiltersR[i].reset()
        }
        for i in 0..<StereoFeed.dryDelayBufSize {
            dryDelayBufL[i] = 0.0
            dryDelayBufR[i] = 0.0
        }
        dryDelayWritePos = 0
        mixInitialized = false
        vDSP_vclr(erEarlyBufL, 1, vDSP_Length(StereoFeed.erBufSize))
        vDSP_vclr(erEarlyBufR, 1, vDSP_Length(StereoFeed.erBufSize))
        vDSP_vclr(erLateBufL, 1, vDSP_Length(StereoFeed.erBufSize))
        vDSP_vclr(erLateBufR, 1, vDSP_Length(StereoFeed.erBufSize))
        erWritePos = 0
        erHpf1L.reset()
        erHpf2L.reset()
        erHpf1R.reset()
        erHpf2R.reset()
        erLpfEarlyStateL = 0.0
        erLpfEarlyStateR = 0.0
        erLpfLateStateL = 0.0
        erLpfLateStateR = 0.0
        erInitialized = false
        speakerSideLowShelfFilter.reset()
        speakerSideHighShelfFilter.reset()
        for i in 0..<3 {
            speakerRevFiltersL[i].reset()
            speakerRevFiltersR[i].reset()
        }
    }

    /// Поблочная интерполяция 5 полос Mid (560–2400 Гц) и 8 статических полос DF-EQ (L/R) + LUFS makeup без щелчков
    private func applyCalibrationAndLUFSMatch(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let sr = max(44100.0, sampleRate)
        updateGoalMidGains(forAngle: targetAngleDeg)
        let g = StereoFeed.headphoneMakeupLinear

        if !filtersInitialized || abs(sr - lastHeadphoneSR) > 0.5 {
            for b in 0..<5 {
                currentMidGainsDB[b] = goalMidGainsDB[b]
            }
            updateStaticDFCoefficients(sr: sr)
            updateMidCoefficients(sr: sr)
            if abs(sr - lastHeadphoneSR) > 0.5 {
                clearFilterDelayLines()
            }
            lastHeadphoneSR = sr
            filtersInitialized = true
        }

        // Разбиваем буфер на подблоки по 64 сэмпла (~1.3 мс) для бесшовной интерполяции параметров
        let subBlock = 64
        var offset = 0
        while offset < frames {
            let count = min(subBlock, frames - offset)
            let alpha = 0.22 // Плавная экспоненциальная сходимость за ~15–20 мс без щелчков

            var needUpdate = false
            for b in 0..<5 {
                if abs(currentMidGainsDB[b] - goalMidGainsDB[b]) > 0.002 {
                    needUpdate = true
                    break
                }
            }

            if needUpdate {
                for b in 0..<5 {
                    currentMidGainsDB[b] += (goalMidGainsDB[b] - currentMidGainsDB[b]) * alpha
                }
                updateMidCoefficients(sr: sr)
            }

            for i in 0..<count {
                let idx = offset + i
                var l = Double(left[idx]) * g
                var r = Double(right[idx]) * g

                var m = 0.5 * (l + r)
                let s = 0.5 * (l - r)

                for b in 0..<5 {
                    m = midFilters[b].process(m)
                }

                l = m + s
                r = m - s

                for b in 0..<8 {
                    l = dfFiltersL[b].process(l)
                    r = dfFiltersR[b].process(r)
                }

                left[idx] = Float(l)
                right[idx] = Float(r)
            }

            offset += count
        }
    }

    private func updateStaticDFCoefficients(sr: Double) {
        for b in 0..<8 {
            let p = StereoFeed.dfBaseBands[b]
            dfFiltersL[b].updatePeaking(freq: p.freq, q: p.q, gainDB: p.gainDB, sampleRate: sr)
            dfFiltersR[b].updatePeaking(freq: p.freq, q: p.q, gainDB: p.gainDB, sampleRate: sr)
        }
    }

    private func updateMidCoefficients(sr: Double) {
        for b in 0..<5 {
            let tpl = StereoFeed.midTemplate[b]
            midFilters[b].updatePeaking(freq: tpl.freq, q: tpl.q, gainDB: currentMidGainsDB[b], sampleRate: sr)
        }
    }

    private func updateSpeakerShufflerCoefficients(sr: Double) {
        speakerSideLowShelfFilter.updateHighShelf(
            freq: StereoFeed.speakerShufflerLowFreq,
            q: StereoFeed.speakerShufflerQ,
            gainDB: currentSpeakerSideGainDB,
            sampleRate: sr
        )
        speakerSideHighShelfFilter.updateHighShelf(
            freq: StereoFeed.speakerShufflerHighFreq,
            q: StereoFeed.speakerShufflerQ,
            gainDB: -currentSpeakerSideGainDB,
            sampleRate: sr
        )
    }

    /// Поблочная обработка в режиме колонок (Этап 6: без HRTFHQ, полосовой шаффлер Бауэра 240–1750 Гц в Side со спадом к 0 dB на ВЧ,
    /// плавный ход ползунка 10°…35° без мёртвых зон, 100% сохранение моно L+R = 2M и выравнивание громкости BS.1770)
    private func applySpeakerModeShuffler(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let sr = max(44100.0, sampleRate)
        let clampedDeg = max(10.0, min(35.0, physicalSpeakerAngleDeg))
        let physRad = clampedDeg * .pi / 180.0
        let ratio = StereoFeed.speakerSinRef35 / max(0.15, sin(physRad))
        let rawSideDB = max(0.0, 20.0 * log10(max(1.0, ratio)))
        let goalSideDB = StereoFeed.speakerShufflerMaxDB * tanh((StereoFeed.speakerShufflerKnee * rawSideDB) / StereoFeed.speakerShufflerMaxDB)
        let sidePowerLinear = pow(10.0, goalSideDB / 10.0)
        let estLoudnessChangeDB = 10.0 * log10(1.0 + StereoFeed.speakerSideLoudnessWeight * (sidePowerLinear - 1.0))
        let goalSpeakerMakeup = pow(10.0, -estLoudnessChangeDB / 20.0)
        let goalRevPct = max(0.0, min(3.0, cycleReverbBlend * 100.0))

        if !speakerFiltersInitialized || abs(sr - lastSpeakerSR) > 0.5 {
            currentSpeakerSideGainDB = goalSideDB
            currentSpeakerMakeupLinear = goalSpeakerMakeup
            currentSpeakerReverbPct = goalRevPct
            updateSpeakerShufflerCoefficients(sr: sr)
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
                updateSpeakerShufflerCoefficients(sr: sr)
            }
            if abs(currentSpeakerReverbPct - goalRevPct) > 0.001 {
                currentSpeakerReverbPct += (goalRevPct - currentSpeakerReverbPct) * alpha
                updateSpeakerReverbFilterCoefficients(sr: sr)
            }
            let startMakeup = currentSpeakerMakeupLinear
            currentSpeakerMakeupLinear += (goalSpeakerMakeup - currentSpeakerMakeupLinear) * alpha
            let endMakeup = currentSpeakerMakeupLinear
            let invCount = 1.0 / Double(max(1, count))
            let revActive = currentSpeakerReverbPct > 1e-4

            for i in 0..<count {
                let idx = offset + i
                let frac = Double(i + 1) * invCount
                let g = startMakeup + (endMakeup - startMakeup) * frac
                var l = Double(left[idx]) * g
                var r = Double(right[idx]) * g

                let m = 0.5 * (l + r)
                var s = 0.5 * (l - r)
                s = speakerSideLowShelfFilter.process(s)
                s = speakerSideHighShelfFilter.process(s)
                l = m + s
                r = m - s

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

    private func updateERFilterCoefficients(sr: Double) {
        let qButter = 0.70710678
        erHpf1L.updateHighPass(freq: 280.0, q: qButter, sampleRate: sr)
        erHpf2L.updateHighPass(freq: 280.0, q: qButter, sampleRate: sr)
        erHpf1R.updateHighPass(freq: 280.0, q: qButter, sampleRate: sr)
        erHpf2R.updateHighPass(freq: 280.0, q: qButter, sampleRate: sr)
        erLpfEarlyAlpha = 1.0 - exp(-2.0 * Double.pi * 5600.0 / sr)
        erLpfLateAlpha = 1.0 - exp(-2.0 * Double.pi * 3400.0 / sr)
    }

    @inline(__always)
    private func readERLinear(_ buf: UnsafeMutablePointer<Float>, delaySamples: Double) -> Float {
        let d = max(0.0, min(Double(StereoFeed.erBufSize - 2), delaySamples))
        let i0 = Int(d)
        let frac = Float(d - Double(i0))
        let p0 = (erWritePos - i0) & StereoFeed.erBufMask
        let p1 = (erWritePos - (i0 + 1)) & StereoFeed.erBufMask
        return buf[p0] + (buf[p1] - buf[p0]) * frac
    }

    /// Плавный Dry / Wet микс для режима наушников с компенсацией микрозадержки .HRTFHQ, ранними отражениями (ER) и сохранением LUFS
    private func applyDryWetMixAndDelay(
        rawL: UnsafeMutablePointer<Float>,
        rawR: UnsafeMutablePointer<Float>,
        wetL: UnsafeMutablePointer<Float>,
        wetR: UnsafeMutablePointer<Float>,
        dryOutL: UnsafeMutablePointer<Float>,
        dryOutR: UnsafeMutablePointer<Float>,
        frames: Int
    ) {
        guard frames > 0 else { return }
        let sr = max(44100.0, sampleRate)
        let goalMix = max(0.0, min(1.0, targetEffectMix))
        let delay = max(0, min(StereoFeed.dryDelayBufSize - 1, dryDelaySamples))
        let roomAmt = min(1.0, max(0.0, cycleReverbBlend / 0.03))
        let goalERMaster = (roomAmt > 1e-4) ? (0.50 * pow(roomAmt, 0.85)) : 0.0
        let goalAngleNorm = min(1.0, max(0.0, (targetAngleDeg - 15.0) / 45.0))

        if !mixInitialized {
            currentEffectMix = goalMix
            mixInitialized = true
        }
        if !erInitialized || abs(sr - lastERSR) > 0.5 {
            updateERFilterCoefficients(sr: sr)
            currentERMasterGain = goalERMaster
            currentERAngleNorm = goalAngleNorm
            if abs(sr - lastERSR) > 0.5 {
                vDSP_vclr(erEarlyBufL, 1, vDSP_Length(StereoFeed.erBufSize))
                vDSP_vclr(erEarlyBufR, 1, vDSP_Length(StereoFeed.erBufSize))
                vDSP_vclr(erLateBufL, 1, vDSP_Length(StereoFeed.erBufSize))
                vDSP_vclr(erLateBufR, 1, vDSP_Length(StereoFeed.erBufSize))
                erWritePos = 0
                erHpf1L.reset(); erHpf2L.reset()
                erHpf1R.reset(); erHpf2R.reset()
                erLpfEarlyStateL = 0.0; erLpfEarlyStateR = 0.0
                erLpfLateStateL = 0.0; erLpfLateStateR = 0.0
            }
            lastERSR = sr
            erInitialized = true
        }

        let msToSmp = sr / 1000.0
        let baseD = Double(delay)
        let subBlock = 64
        var offset = 0
        while offset < frames {
            let count = min(subBlock, frames - offset)
            let alpha = 0.22

            let startMix = currentEffectMix
            if abs(goalMix - currentEffectMix) > 0.0005 {
                currentEffectMix += (goalMix - currentEffectMix) * alpha
            } else {
                currentEffectMix = goalMix
            }
            let endMix = currentEffectMix

            let startERMaster = currentERMasterGain
            if abs(goalERMaster - currentERMasterGain) > 0.0002 {
                currentERMasterGain += (goalERMaster - currentERMasterGain) * alpha
            } else {
                currentERMasterGain = goalERMaster
            }
            let endERMaster = currentERMasterGain

            let startAngleNorm = currentERAngleNorm
            if abs(goalAngleNorm - currentERAngleNorm) > 0.0005 {
                currentERAngleNorm += (goalAngleNorm - currentERAngleNorm) * alpha
            } else {
                currentERAngleNorm = goalAngleNorm
            }
            let endAngleNorm = currentERAngleNorm

            let invCount = 1.0 / Double(max(1, count))

            for i in 0..<count {
                let idx = offset + i
                let frac = Double(i + 1) * invCount
                let m = startMix + (endMix - startMix) * frac
                let c = 1.0 + 0.16 * m * (1.0 - m)
                let dryG = Float((1.0 - m) * c)
                let wetG = Float(m * c)

                let inL = rawL[idx]
                let inR = rawR[idx]

                dryDelayBufL[dryDelayWritePos] = inL
                dryDelayBufR[dryDelayWritePos] = inR
                let readPos = (dryDelayWritePos - delay) & StereoFeed.dryDelayBufMask
                dryDelayWritePos = (dryDelayWritePos + 1) & StereoFeed.dryDelayBufMask
                let delayedL = dryDelayBufL[readPos]
                let delayedR = dryDelayBufR[readPos]

                let erMaster = startERMaster + (endERMaster - startERMaster) * frac
                let xl = erHpf2L.process(erHpf1L.process(Double(inL)))
                let xr = erHpf2R.process(erHpf1R.process(Double(inR)))
                erLpfEarlyStateL += erLpfEarlyAlpha * (xl - erLpfEarlyStateL)
                erLpfEarlyStateR += erLpfEarlyAlpha * (xr - erLpfEarlyStateR)
                erLpfLateStateL  += erLpfLateAlpha  * (xl - erLpfLateStateL)
                erLpfLateStateR  += erLpfLateAlpha  * (xr - erLpfLateStateR)

                erEarlyBufL[erWritePos] = Float(erLpfEarlyStateL)
                erEarlyBufR[erWritePos] = Float(erLpfEarlyStateR)
                erLateBufL[erWritePos]  = Float(erLpfLateStateL)
                erLateBufR[erWritePos]  = Float(erLpfLateStateR)

                if erMaster > 1e-6 && wetG > 1e-6 {
                    let u = startAngleNorm + (endAngleNorm - startAngleNorm) * frac
                    let latScale = Float(0.68 + 0.64 * u)

                    let tCeil = 6.7
                    let tNear = 9.6 - 2.4 * u
                    let tOpp  = 11.2 + 2.0 * u
                    let tFrnt = 14.7 + 0.5 * (1.0 - u)
                    let tBack = 19.3
                    let tCrnr = 24.7 - 0.9 * u

                    var erL: Float = 0.0
                    var erR: Float = 0.0

                    // 1. Потолок (early)
                    erL += Float(0.32) * readERLinear(erEarlyBufL, delaySamples: baseD + tCeil * msToSmp)
                        + Float(0.24) * readERLinear(erEarlyBufR, delaySamples: baseD + (tCeil + 0.19 + 0.31) * msToSmp)
                    erR += Float(0.32) * readERLinear(erEarlyBufR, delaySamples: baseD + (tCeil + 0.31) * msToSmp)
                        + Float(0.24) * readERLinear(erEarlyBufL, delaySamples: baseD + (tCeil + 0.19) * msToSmp)

                    // 2. Ближняя боковая стена (early)
                    let gNearI = Float(-0.52) * latScale
                    let gNearC = Float(-0.20) * latScale
                    erL += gNearI * readERLinear(erEarlyBufL, delaySamples: baseD + tNear * msToSmp)
                        + gNearC * readERLinear(erEarlyBufR, delaySamples: baseD + (tNear + 0.54 + 0.43) * msToSmp)
                    erR += gNearI * readERLinear(erEarlyBufR, delaySamples: baseD + (tNear + 0.43) * msToSmp)
                        + gNearC * readERLinear(erEarlyBufL, delaySamples: baseD + (tNear + 0.54) * msToSmp)

                    // 3. Противоположная боковая стена — перекрёстный приход (early)
                    let gOppI = Float(0.18) * latScale
                    let gOppC = Float(0.48) * latScale
                    erL += gOppI * readERLinear(erEarlyBufL, delaySamples: baseD + (tOpp + 0.56) * msToSmp)
                        + gOppC * readERLinear(erEarlyBufR, delaySamples: baseD + (tOpp + 0.37) * msToSmp)
                    erR += gOppI * readERLinear(erEarlyBufR, delaySamples: baseD + (tOpp + 0.56 + 0.37) * msToSmp)
                        + gOppC * readERLinear(erEarlyBufL, delaySamples: baseD + tOpp * msToSmp)

                    // 4. Передняя стена (late)
                    erL += Float(-0.34) * readERLinear(erLateBufL, delaySamples: baseD + tFrnt * msToSmp)
                        + Float(-0.26) * readERLinear(erLateBufR, delaySamples: baseD + (tFrnt + 0.25 + 0.53) * msToSmp)
                    erR += Float(-0.34) * readERLinear(erLateBufR, delaySamples: baseD + (tFrnt + 0.53) * msToSmp)
                        + Float(-0.26) * readERLinear(erLateBufL, delaySamples: baseD + (tFrnt + 0.25) * msToSmp)

                    // 5. Задняя стена (late)
                    erL += Float(0.28) * readERLinear(erLateBufL, delaySamples: baseD + (tBack + 0.21) * msToSmp)
                        + Float(0.22) * readERLinear(erLateBufR, delaySamples: baseD + (tBack + 0.41) * msToSmp)
                    erR += Float(0.28) * readERLinear(erLateBufR, delaySamples: baseD + (tBack + 0.21 + 0.41) * msToSmp)
                        + Float(0.22) * readERLinear(erLateBufL, delaySamples: baseD + tBack * msToSmp)

                    // 6. Угловое отражение 2-го порядка (late)
                    let gCrnI = Float(-0.16) * latScale
                    let gCrnC = Float(-0.32) * latScale
                    erL += gCrnI * readERLinear(erLateBufL, delaySamples: baseD + (tCrnr + 0.50) * msToSmp)
                        + gCrnC * readERLinear(erLateBufR, delaySamples: baseD + (tCrnr + 0.61) * msToSmp)
                    erR += gCrnI * readERLinear(erLateBufR, delaySamples: baseD + (tCrnr + 0.50 + 0.61) * msToSmp)
                        + gCrnC * readERLinear(erLateBufL, delaySamples: baseD + tCrnr * msToSmp)

                    let erScale = Float(erMaster) * wetG
                    dryOutL[idx] = delayedL * dryG + erL * erScale
                    dryOutR[idx] = delayedR * dryG + erR * erScale
                } else {
                    dryOutL[idx] = delayedL * dryG
                    dryOutR[idx] = delayedR * dryG
                }
                erWritePos = (erWritePos + 1) & StereoFeed.erBufMask

                wetL[idx] *= wetG
                wetR[idx] *= wetG
            }

            offset += count
        }
    }

    private func populateStashIfNeeded(frames: Int, needL: Bool, needR: Bool, needDirect: Bool, needDry: Bool) {
        let alreadyConsumed = (needL && consumedL) || (needR && consumedR) || (needDirect && consumedDirect) || (needDry && consumedDry)
        if alreadyConsumed || frames != stashFrames {
            // Фиксируем единый снимок настроек на весь текущий цикл рендера (для L, R, Direct и Dry)
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

            ring.read(left: rawStashL, right: rawStashR, count: frames)
            if !cycleBypass {
                stashL.update(from: rawStashL, count: frames)
                stashR.update(from: rawStashR, count: frames)
                if cycleSpeakerMode {
                    applySpeakerModeShuffler(left: stashL, right: stashR, frames: frames)
                } else {
                    applyCalibrationAndLUFSMatch(left: stashL, right: stashR, frames: frames)
                    applyDryWetMixAndDelay(
                        rawL: rawStashL,
                        rawR: rawStashR,
                        wetL: stashL,
                        wetR: stashR,
                        dryOutL: dryStashL,
                        dryOutR: dryStashR,
                        frames: frames
                    )
                }
            }
            stashFrames = frames
            consumedL = false
            consumedR = false
            consumedDirect = false
            consumedDry = false
        }
    }

    /// Моно-канал для 3D-источника (в режиме наушников — основной сигнал + реверб, в режиме колонок — только посыл в реверберацию комнаты).
    func fetchMono(channel: Int, into dst: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames <= StereoFeed.maxFrames else {
            vDSP_vclr(dst, 1, vDSP_Length(frames))
            return
        }
        populateStashIfNeeded(frames: frames, needL: channel == 0, needR: channel != 0, needDirect: false, needDry: false)
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
        populateStashIfNeeded(frames: frames, needL: false, needR: false, needDirect: true, needDry: false)
        consumedDirect = true
        guard cycleBypass || cycleSpeakerMode else {
            vDSP_vclr(left, 1, vDSP_Length(frames))
            vDSP_vclr(right, 1, vDSP_Length(frames))
            return
        }
        if cycleBypass {
            left.update(from: rawStashL, count: frames)
            right.update(from: rawStashR, count: frames)
        } else {
            left.update(from: stashL, count: frames)
            right.update(from: stashR, count: frames)
        }
    }

    /// Выровненный по задержке Dry-путь для плавного смешивания Dry/Wet в режиме наушников (до лимитера).
    func fetchDryAligned(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames <= StereoFeed.maxFrames else {
            vDSP_vclr(left, 1, vDSP_Length(frames))
            vDSP_vclr(right, 1, vDSP_Length(frames))
            return
        }
        populateStashIfNeeded(frames: frames, needL: false, needR: false, needDirect: false, needDry: true)
        consumedDry = true
        guard !cycleBypass && !cycleSpeakerMode else {
            vDSP_vclr(left, 1, vDSP_Length(frames))
            vDSP_vclr(right, 1, vDSP_Length(frames))
            return
        }
        left.update(from: dryStashL, count: frames)
        right.update(from: dryStashR, count: frames)
    }
}

public final class SpatialEngine {
    private var engine = AVAudioEngine()
    public var currentEngine: AVAudioEngine { engine }
    private var environment = AVAudioEnvironmentNode()
    private var limiterNode: AVAudioUnitEffect?
    
    private var leftSourceNode: AVAudioSourceNode?
    private var rightSourceNode: AVAudioSourceNode?
    private var drySourceNode: AVAudioSourceNode?
    private var bypassSourceNode: AVAudioSourceNode?
    private var spatialMixerNode: AVAudioMixerNode?

    private static var cachedHRTFDelaySamples: [Int: Int] = [:]
    
    private let feed: StereoFeed
    
    public private(set) var isRunning: Bool = false
    public private(set) var sampleRate: Double = 44100.0
    private var currentOutputDeviceID: AudioDeviceID?
    
    public var onConfigurationChange: (() -> Void)?
    private var configChangeObserver: NSObjectProtocol?
    public var isEngineActuallyRunning: Bool { engine.isRunning }
    
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

    public var effectMix: Float = 1.0 { // 0.0 ... 1.0 (сила эффекта в наушниках: Dry / Wet)
        didSet {
            guard abs(effectMix - oldValue) > 0.0001 else { return }
            feed.targetEffectMix = Double(min(1.0, max(0.0, effectMix)))
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

    /// Калибровка наушников и выравнивание громкости выполняются внутри StereoFeed,
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
            // В режиме наушников используются чистые ранние отражения (ER), системный .smallRoom отключён
            left.reverbBlend = 0.0
            right.reverbBlend = 0.0
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
        observeConfigurationChange()
    }
    
    deinit {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        teardownCurrentGraph()
    }

    private func observeConfigurationChange() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isRunning else { return }
            debugLog("[SpatialEngine] AVAudioEngineConfigurationChange -> engine stopped by system")
            self.isRunning = false
            self.feed.resetState()
            self.onConfigurationChange?()
        }
    }
    
    private static func measureHRTFDelaySamples(sampleRate: Double) -> Int {
        let srKey = Int(round(sampleRate))
        if let cached = cachedHRTFDelaySamples[srKey] {
            return cached
        }
        let fallback: Int
        switch srKey {
        case 44100: fallback = 11
        case 48000: fallback = 5
        case 88200: fallback = 15
        case 96000: fallback = 16
        default: fallback = max(0, min(127, Int(round(sampleRate * 0.00011))))
        }
        guard let monoFmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let stereoFmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            cachedHRTFDelaySamples[srKey] = fallback
            return fallback
        }
        let offlineEngine = AVAudioEngine()
        let env = AVAudioEnvironmentNode()
        var impulseSent = false
        let src = AVAudioSourceNode(format: monoFmt) { _, _, frameCount, abl in
            let ptr = UnsafeMutableAudioBufferListPointer(abl)[0].mData!.assumingMemoryBound(to: Float.self)
            let n = Int(frameCount)
            for i in 0..<n { ptr[i] = 0.0 }
            if !impulseSent && n > 64 {
                ptr[64] = 1.0
                impulseSent = true
            }
            return noErr
        }
        offlineEngine.attach(src)
        offlineEngine.attach(env)
        offlineEngine.connect(src, to: env, format: monoFmt)
        offlineEngine.connect(env, to: offlineEngine.mainMixerNode, format: stereoFmt)
        env.distanceAttenuationParameters.rolloffFactor = 0.0
        env.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        src.renderingAlgorithm = .HRTFHQ
        let rad = Float(30.0 * .pi / 180.0)
        src.position = AVAudio3DPoint(x: -sin(rad), y: 0.0, z: -cos(rad))
        src.reverbBlend = 0.0

        do {
            try offlineEngine.enableManualRenderingMode(.offline, format: stereoFmt, maximumFrameCount: 256)
            try offlineEngine.start()
            guard let buf = AVAudioPCMBuffer(pcmFormat: stereoFmt, frameCapacity: 256) else {
                offlineEngine.stop()
                cachedHRTFDelaySamples[srKey] = fallback
                return fallback
            }
            _ = try offlineEngine.renderOffline(256, to: buf)
            offlineEngine.stop()
            if let ch0 = buf.floatChannelData?[0] {
                var peakIdx = 64
                var peakAbs: Float = 0.0
                for i in 64..<min(256, Int(buf.frameLength)) {
                    let a = abs(ch0[i])
                    if a > peakAbs {
                        peakAbs = a
                        peakIdx = i
                    }
                }
                if peakAbs > 0.01 {
                    let delta = max(0, min(127, peakIdx - 64))
                    cachedHRTFDelaySamples[srKey] = delta
                    print("[SpatialEngine] Автокалибровка задержки HRTFHQ @ \(srKey) Гц: \(delta) сэмплов")
                    return delta
                }
            }
        } catch {
            offlineEngine.stop()
            print("[SpatialEngine] Автокалибровка задержки HRTFHQ ошибка (\(srKey) Гц): \(error)")
        }
        cachedHRTFDelaySamples[srKey] = fallback
        return fallback
    }

    private func teardownCurrentGraph() {
        stop()
        engine.stop()
        for node in [leftSourceNode, rightSourceNode, drySourceNode, bypassSourceNode] {
            if let node = node, node.engine != nil { engine.detach(node) }
        }
        leftSourceNode = nil
        rightSourceNode = nil
        drySourceNode = nil
        bypassSourceNode = nil
        if let mix = spatialMixerNode {
            if mix.engine != nil { engine.detach(mix) }
            spatialMixerNode = nil
        }
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
        observeConfigurationChange()
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
        self.feed.targetEffectMix = Double(min(1.0, max(0.0, effectMix)))
        self.feed.dryDelaySamples = SpatialEngine.measureHRTFDelaySamples(sampleRate: actualRate)
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
        
        // 5. Выровненный по задержке Dry-источник (для плавного смешивания Dry/Wet до лимитера в режиме наушников)
        let dryNode = AVAudioSourceNode(format: stereoFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count >= 2,
                  let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            feed.fetchDryAligned(left: l, right: r, frames: Int(frameCount))
            return noErr
        }

        // 6. Прямой стерео-источник (Bypass и Колонки): мимо 3D-сцены и лимитера, единичное усиление
        let bypassNode = AVAudioSourceNode(format: stereoFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count >= 2,
                  let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            feed.fetchStereo(left: l, right: r, frames: Int(frameCount))
            return noErr
        }

        let spatialMixer = AVAudioMixerNode()
        spatialMixer.outputVolume = 1.0

        self.leftSourceNode = leftNode
        self.rightSourceNode = rightNode
        self.drySourceNode = dryNode
        self.bypassSourceNode = bypassNode
        self.spatialMixerNode = spatialMixer

        engine.attach(leftNode)
        engine.attach(rightNode)
        engine.attach(dryNode)
        engine.attach(bypassNode)
        engine.attach(spatialMixer)

        // Цепочки обработки:
        //   3D (Наушники): (L/R -> Environment + DryAligned) -> SpatialMixer -> Peak Limiter -> Главный микшер -> Выход
        //   Bypass/Колонки: Стерео -----------------------------------------------------------> Главный микшер -> Выход
        engine.connect(leftNode, to: environment, format: monoFormat)
        engine.connect(rightNode, to: environment, format: monoFormat)
        engine.connect(environment, to: spatialMixer, format: stereoFormat)
        engine.connect(dryNode, to: spatialMixer, format: stereoFormat)
        engine.connect(spatialMixer, to: limiter, format: stereoFormat)
        engine.connect(limiter, to: engine.mainMixerNode, format: stereoFormat)
        engine.connect(bypassNode, to: engine.mainMixerNode, format: stereoFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: stereoFormat)
        
        // 6. Акустика комнаты (для режима колонок .smallRoom; в наушниках используются чистые ранние отражения)
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
