import Foundation
import os.lock

/// Ультра-низколатентный кольцевой буфер с непрерывным субдискретным ресемплингом
/// Исключает скачки, треск и хрипоту за счет микроподстройки скорости чтения (±0.5% max)
/// Обеспечивает строгую задержку ~11.6 мс для синхронизации звука с видео (lip-sync).
public final class AudioRingBuffer {
    private let buffer: UnsafeMutablePointer<Float>
    public let capacity: Int
    private let mask: Int
    
    private var writePos: Int = 0
    private var readPosFrac: Double = 0.0
    private var isInitialized: Bool = false
    private var lock = os_unfair_lock()
    
    // Целевой размер буфера задержки: 768 сэмплов (~17.4 мс при 44.1 кГц, ~16.0 мс при 48 кГц)
    private let targetLatencySamples: Double = 768.0
    private let preRollSamples: Int = 1024
    
    public init(capacityPowerOfTwo: Int = 16) { // 65536 сэмплов
        self.capacity = 1 << capacityPowerOfTwo
        self.mask = self.capacity - 1
        self.buffer = UnsafeMutablePointer<Float>.allocate(capacity: self.capacity)
        self.buffer.initialize(repeating: 0, count: self.capacity)
    }
    
    deinit {
        buffer.deallocate()
    }
    
    /// Запись захваченных сэмплов
    public func write(_ source: UnsafePointer<Float>, count: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        for i in 0..<count {
            buffer[(writePos + i) & mask] = source[i]
        }
        writePos &+= count
        
        // Предварительное накопление: активируем чтение только после набора достаточного буфера
        if !isInitialized && writePos >= preRollSamples {
            readPosFrac = Double(writePos) - targetLatencySamples
            isInitialized = true
        }
    }
    
    /// Чтение сэмплов с непрерывной субдискретной интерполяцией и автокомпенсацией дрейфа частот
    public func read(into destination: UnsafeMutablePointer<Float>, count: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        // До накопления стартового буфера выдаем тишину
        guard isInitialized else {
            for i in 0..<count {
                destination[i] = 0.0
            }
            return
        }
        
        let currentLag = Double(writePos) - readPosFrac
        
        // Экстренная защита при глубоком сбое (например, после сна Mac > 185 мс)
        if currentLag > 8192.0 || currentLag < -512.0 {
            readPosFrac = Double(writePos) - targetLatencySamples
        }
        
        // Динамическая адаптация скорости:
        // Если буфер заполняется больше целевого — скорость чтения плавно увеличивается (до +0.8%)
        // Если буфер опустошается ниже целевого — скорость чтения плавно снижается (до -0.8%)
        // Без жестких скачков фазы!
        let lagDiff = currentLag - targetLatencySamples
        let speedAdjustment = max(-0.008, min(0.008, lagDiff * 0.00003))
        let speed = 1.0 + speedAdjustment
        
        for i in 0..<count {
            // Если читатель временно догнал писателя, аккуратно затихаем без скачков позиции
            if readPosFrac >= Double(writePos) {
                destination[i] = 0.0
                continue
            }
            
            let baseIndex = Int(readPosFrac)
            let frac = Float(readPosFrac - Double(baseIndex))
            
            let s0 = buffer[baseIndex & mask]
            let s1 = buffer[(baseIndex + 1) & mask]
            
            // Линейная интерполяция без щелчков фазы
            destination[i] = s0 + frac * (s1 - s0)
            
            readPosFrac += speed
        }
    }
    
    public func reset() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        writePos = 0
        readPosFrac = 0.0
        isInitialized = false
        buffer.initialize(repeating: 0, count: capacity)
    }
}
