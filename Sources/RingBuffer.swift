import Foundation
import os.lock
import Accelerate

/// Стерео кольцевой буфер между захватом (BlackHole) и выводом (физическое устройство)
/// с компенсацией дрейфа тактовых генераторов двух устройств.
///
/// - Один общий указатель чтения для L/R: каналы всегда фазово синхронны.
/// - Заполнение буфера сглаживается EMA (~1.4 с), поправка скорости ограничена ±300 ppm.
///   Это на порядки меньше слышимого порога «плавания» высоты (реальный дрейф часов — десятки ppm).
/// - Дробная позиция чтения интерполируется полифазным windowed-sinc фильтром
///   (64 отвода, окно Кайзера, 512 фаз с линейной интерполяцией между фазами).
///   АЧХ ровная практически до Найквиста — без «замыливания» верха, как у линейной интерполяции.
/// - Буфер хранится в зеркальном виде (2 × capacity), чтобы окно фильтра всегда было непрерывным в памяти.
public final class AudioRingBuffer {
    // MARK: - Параметры интерполятора
    private static let taps = 64
    private static let halfTaps = 32              // окно: (halfTaps - 1) сэмплов слева, halfTaps справа
    private static let phases = 512
    private static let cutoff = 0.485             // нормированная частота среза (циклы/сэмпл), 0.5 = Найквист
    private static let kaiserBeta = 8.0

    // MARK: - Параметры компенсации дрейфа
    // Целевая задержка: 2048 сэмплов (~46 мс при 44.1 кГц, ~43 мс при 48 кГц)
    private let targetLatency: Double = 2048.0
    private let lagTimeConstant: Double = 65536.0 // постоянная времени сглаживания заполнения, в сэмплах
    private let kp: Double = 1.5e-6               // коэффициент регулятора скорости
    private let maxSpeedDeviation: Double = 0.0003 // ±300 ppm

    // MARK: - Хранилище
    public let capacity: Int
    private let mask: Int
    private let bufL: UnsafeMutablePointer<Float>
    private let bufR: UnsafeMutablePointer<Float>
    private let filterTable: UnsafeMutablePointer<Float>   // (phases + 1) × taps

    // MARK: - Состояние (защищено lock; данные буфера читаются вне lock — SPSC)
    private var lock = os_unfair_lock()
    private var writePos: Int = 0
    private var readPos: Double = 0.0
    private var lagAvg: Double = 0.0
    private var isInitialized: Bool = false
    private var isRefilling: Bool = false

    public init(capacityPowerOfTwo: Int = 15) { // 32768 сэмплов на канал
        self.capacity = 1 << capacityPowerOfTwo
        self.mask = self.capacity - 1
        self.bufL = UnsafeMutablePointer<Float>.allocate(capacity: capacity * 2)
        self.bufR = UnsafeMutablePointer<Float>.allocate(capacity: capacity * 2)
        self.bufL.initialize(repeating: 0, count: capacity * 2)
        self.bufR.initialize(repeating: 0, count: capacity * 2)
        self.filterTable = AudioRingBuffer.makeFilterTable()
    }

    deinit {
        bufL.deallocate()
        bufR.deallocate()
        filterTable.deallocate()
    }

    // MARK: - Таблица полифазного фильтра

    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        let halfX = x / 2.0
        for k in 1..<50 {
            term *= (halfX / Double(k)) * (halfX / Double(k))
            sum += term
            if term < sum * 1e-12 { break }
        }
        return sum
    }

    private static func makeFilterTable() -> UnsafeMutablePointer<Float> {
        let rows = phases + 1
        let table = UnsafeMutablePointer<Float>.allocate(capacity: rows * taps)
        let i0Beta = besselI0(kaiserBeta)
        let span = Double(halfTaps)

        for p in 0..<rows {
            let frac = Double(p) / Double(phases)
            var coeffs = [Double](repeating: 0, count: taps)
            var sum = 0.0
            for k in 0..<taps {
                // Расстояние от сэмпла (base + k - (halfTaps-1)) до точки чтения (base + frac)
                let tau = Double(k - (halfTaps - 1)) - frac
                let x = 2.0 * cutoff * tau
                let sinc = abs(x) < 1e-12 ? 1.0 : sin(Double.pi * x) / (Double.pi * x)
                let u = tau / span
                let window = abs(u) >= 1.0 ? 0.0 : besselI0(kaiserBeta * sqrt(1.0 - u * u)) / i0Beta
                let h = 2.0 * cutoff * sinc * window
                coeffs[k] = h
                sum += h
            }
            // Нормировка на единичное усиление по постоянному току для каждой фазы
            for k in 0..<taps {
                table[p * taps + k] = Float(coeffs[k] / sum)
            }
        }
        return table
    }

    // MARK: - Запись (поток захвата)

    public func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let n = min(count, capacity)
        for i in 0..<n {
            let idx = (writePos + i) & mask
            let l = left[i]
            let r = right[i]
            bufL[idx] = l
            bufL[idx + capacity] = l
            bufR[idx] = r
            bufR[idx + capacity] = r
        }
        writePos &+= n

        // Предварительное накопление: чтение стартует только после набора целевой задержки
        if !isInitialized && writePos >= Int(targetLatency) + AudioRingBuffer.halfTaps {
            readPos = Double(writePos) - targetLatency
            lagAvg = targetLatency
            isRefilling = false
            isInitialized = true
        }
    }

    // MARK: - Чтение (поток вывода)

    public func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        os_unfair_lock_lock(&lock)
        let wp = writePos
        let initialized = isInitialized
        var rp = readPos
        var avg = lagAvg
        var refilling = isRefilling
        os_unfair_lock_unlock(&lock)

        guard initialized, count > 0 else {
            vDSP_vclr(left, 1, vDSP_Length(count))
            vDSP_vclr(right, 1, vDSP_Length(count))
            return
        }

        let taps = AudioRingBuffer.taps
        let halfTaps = AudioRingBuffer.halfTaps
        let phases = AudioRingBuffer.phases
        let lag = Double(wp) - rp

        // Переполнение (например, после сна Mac или долгой остановки вывода) — жёсткая ресинхронизация
        if lag > Double(capacity / 2) {
            rp = Double(wp) - targetLatency
            avg = targetLatency
            refilling = false
        }

        // После опустошения ждём, пока буфер снова наберёт целевую задержку (без повторов и скачков назад)
        if refilling && (Double(wp) - rp) >= targetLatency {
            refilling = false
            avg = targetLatency
        }

        var speed = 1.0
        if !refilling {
            let currentLag = Double(wp) - rp
            let alpha = min(1.0, Double(count) / lagTimeConstant)
            avg += (currentLag - avg) * alpha
            let adj = max(-maxSpeedDeviation, min(maxSpeedDeviation, kp * (avg - targetLatency)))
            speed = 1.0 + adj

            // Хватает ли данных на весь блок (с учётом правой половины окна фильтра)?
            let lastNeeded = Int(rp + speed * Double(count - 1)) + halfTaps
            if lastNeeded >= wp {
                refilling = true
            }
        }

        if refilling {
            vDSP_vclr(left, 1, vDSP_Length(count))
            vDSP_vclr(right, 1, vDSP_Length(count))
        } else {
            for i in 0..<count {
                let base = Int(rp)
                let frac = rp - Double(base)
                let pf = frac * Double(phases)
                var p = Int(pf)
                if p >= phases { p = phases - 1 }
                let pw = Float(pf - Double(p))

                let start = (base - (halfTaps - 1)) & mask
                let c0 = UnsafePointer(filterTable + p * taps)
                let c1 = UnsafePointer(filterTable + (p + 1) * taps)

                var l0: Float = 0, l1: Float = 0, r0: Float = 0, r1: Float = 0
                vDSP_dotpr(bufL + start, 1, c0, 1, &l0, vDSP_Length(taps))
                vDSP_dotpr(bufL + start, 1, c1, 1, &l1, vDSP_Length(taps))
                vDSP_dotpr(bufR + start, 1, c0, 1, &r0, vDSP_Length(taps))
                vDSP_dotpr(bufR + start, 1, c1, 1, &r1, vDSP_Length(taps))

                left[i] = l0 + pw * (l1 - l0)
                right[i] = r0 + pw * (r1 - r0)

                rp += speed
            }
        }

        os_unfair_lock_lock(&lock)
        // Если за время чтения произошёл reset() — не затираем новое состояние
        if isInitialized {
            readPos = rp
            lagAvg = avg
            isRefilling = refilling
        }
        os_unfair_lock_unlock(&lock)
    }

    public func reset() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        writePos = 0
        readPos = 0.0
        lagAvg = 0.0
        isInitialized = false
        isRefilling = false
        bufL.initialize(repeating: 0, count: capacity * 2)
        bufR.initialize(repeating: 0, count: capacity * 2)
    }
}
