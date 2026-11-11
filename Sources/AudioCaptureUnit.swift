import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import Accelerate
import os.lock

public final class AudioCaptureUnit {
    private var audioUnit: AudioComponentInstance?
    private let ringBuffer: AudioRingBuffer
    
    public private(set) var isRunning: Bool = false
    public private(set) var sampleRate: Double = 44100.0
    public private(set) var peakLevelL: Float = 0.0
    public private(set) var peakLevelR: Float = 0.0
    private var currentDeviceID: AudioDeviceID?
    
    private var scaleLock = os_unfair_lock()
    private var _volumeScale: Float = 1.0
    private var shouldSnapScale: Bool = false
    private var currentScale: Float = 1.0
    
    /// Масштаб компенсации ослабления BlackHole (применяется до записи в кольцевой буфер)
    public var volumeScale: Float {
        get {
            os_unfair_lock_lock(&scaleLock)
            let val = _volumeScale
            os_unfair_lock_unlock(&scaleLock)
            return val
        }
        set {
            os_unfair_lock_lock(&scaleLock)
            _volumeScale = max(0.0, newValue)
            os_unfair_lock_unlock(&scaleLock)
        }
    }
    
    /// Фиксирует текущий масштаб без сглаживающего перехода на старте потока
    public func snapScale() {
        os_unfair_lock_lock(&scaleLock)
        shouldSnapScale = true
        os_unfair_lock_unlock(&scaleLock)
    }
    
    /// Считывает текущий пик левого канала и плавно гасит накопленное значение (чтобы при остановке потока пик не зависал)
    public func consumePeakL() -> Float {
        let val = peakLevelL
        peakLevelL *= 0.82
        if peakLevelL < 0.0001 { peakLevelL = 0.0 }
        return val
    }
    
    /// Считывает текущий пик правого канала и плавно гасит накопленное значение
    public func consumePeakR() -> Float {
        let val = peakLevelR
        peakLevelR *= 0.82
        if peakLevelR < 0.0001 { peakLevelR = 0.0 }
        return val
    }
    
    // Предвыделенные статические буферы для исключения malloc в аудиопотоке
    private static let maxFrames = 4096
    private var leftScratch = [Float](repeating: 0, count: maxFrames)
    private var rightScratch = [Float](repeating: 0, count: maxFrames)
    private let rampScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    private let ablPointer: UnsafeMutableAudioBufferListPointer = AudioBufferList.allocate(maximumBuffers: 2)
    
    // Вспомогательный контекст
    private final class Context {
        var captureUnit: AudioCaptureUnit?
    }
    private var context = Context()
    
    public init(ringBuffer: AudioRingBuffer) {
        self.ringBuffer = ringBuffer
        self.rampScratch.initialize(repeating: 0, count: AudioCaptureUnit.maxFrames)
        self.context.captureUnit = self
    }
    
    deinit {
        stop()
        destroyAudioUnit()
        rampScratch.deallocate()
        free(UnsafeMutableRawPointer(ablPointer.unsafeMutablePointer))
    }
    
    private func applyScale(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        os_unfair_lock_lock(&scaleLock)
        let target = _volumeScale
        let snap = shouldSnapScale
        if snap { shouldSnapScale = false }
        os_unfair_lock_unlock(&scaleLock)
        
        if snap {
            currentScale = target
        }
        
        if frames >= 2 && abs(currentScale - target) > 0.0001 {
            var start = currentScale
            var end = target
            vDSP_vgen(&start, &end, rampScratch, 1, vDSP_Length(frames))
            vDSP_vmul(left, 1, rampScratch, 1, left, 1, vDSP_Length(frames))
            vDSP_vmul(right, 1, rampScratch, 1, right, 1, vDSP_Length(frames))
            currentScale = target
        } else if target <= 0.00001 {
            vDSP_vclr(left, 1, vDSP_Length(frames))
            vDSP_vclr(right, 1, vDSP_Length(frames))
            currentScale = 0.0
        } else if abs(target - 1.0) > 0.0001 {
            var scale = target
            vDSP_vsmul(left, 1, &scale, left, 1, vDSP_Length(frames))
            vDSP_vsmul(right, 1, &scale, right, 1, vDSP_Length(frames))
            currentScale = target
        } else {
            currentScale = 1.0
        }
    }
    
    public func setup(deviceID: AudioDeviceID, sampleRate: Double = 44100.0) -> Bool {
        stop()
        destroyAudioUnit()
        snapScale()
        
        self.sampleRate = sampleRate
        self.currentDeviceID = deviceID
        
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            print("[AudioCaptureUnit] Ошибка: HAL AudioComponent не найден")
            return false
        }
        
        var status = AudioComponentInstanceNew(comp, &audioUnit)
        guard status == noErr, let au = audioUnit else {
            print("[AudioCaptureUnit] Ошибка создания AudioComponentInstance: \(status)")
            return false
        }
        
        // 1. Включаем вход (Bus 1)
        var enableInput: UInt32 = 1
        status = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else { return false }
        
        // 2. Отключаем выход (Bus 0)
        var disableOutput: UInt32 = 0
        status = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &disableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else { return false }
        
        // 3. Задаем устройство
        var devID = deviceID
        status = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            print("[AudioCaptureUnit] Ошибка назначения устройства \(deviceID): \(status)")
            return false
        }
        
        // 4. Задаем формат (2 канала Float32 Non-Interleaved)
        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        
        status = AudioUnitSetProperty(
            au,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &streamFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            print("[AudioCaptureUnit] Ошибка установки формата: \(status)")
            return false
        }
        
        // 5. Назначаем Input Callback (Zero allocation)
        let selfPtr = Unmanaged.passUnretained(self.context).toOpaque()
        var callbackStruct = AURenderCallbackStruct(
            inputProc: { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData -> OSStatus in
                let ctx = Unmanaged<Context>.fromOpaque(inRefCon).takeUnretainedValue()
                guard let unit = ctx.captureUnit, let au = unit.audioUnit else { return noErr }
                
                let frames = min(Int(inNumberFrames), AudioCaptureUnit.maxFrames)
                let frameBytes = UInt32(frames * 4)
                
                unit.leftScratch.withUnsafeMutableBufferPointer { lPtr in
                    unit.rightScratch.withUnsafeMutableBufferPointer { rPtr in
                        unit.ablPointer[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frameBytes, mData: UnsafeMutableRawPointer(lPtr.baseAddress))
                        unit.ablPointer[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frameBytes, mData: UnsafeMutableRawPointer(rPtr.baseAddress))
                        
                        let st = AudioUnitRender(
                            au,
                            ioActionFlags,
                            inTimeStamp,
                            inBusNumber,
                            UInt32(frames),
                            unit.ablPointer.unsafeMutablePointer
                        )
                        
                        if st == noErr {
                            let lBase = lPtr.baseAddress!
                            let rBase = rPtr.baseAddress!
                            unit.applyScale(left: lBase, right: rBase, frames: frames)
                            unit.ringBuffer.write(left: lBase, right: rBase, count: frames)
                            
                            var maxL: Float = 0.0
                            var maxR: Float = 0.0
                            vDSP_maxmgv(lBase, 1, &maxL, vDSP_Length(frames))
                            vDSP_maxmgv(rBase, 1, &maxR, vDSP_Length(frames))
                            unit.peakLevelL = max(unit.peakLevelL * 0.95, maxL)
                            unit.peakLevelR = max(unit.peakLevelR * 0.95, maxR)
                        }
                    }
                }
                
                return noErr
            },
            inputProcRefCon: selfPtr
        )
        
        status = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else { return false }
        
        // 6. Инициализация
        status = AudioUnitInitialize(au)
        guard status == noErr else {
            print("[AudioCaptureUnit] Ошибка инициализации AUHAL: \(status)")
            return false
        }
        
        return true
    }
    
    public func start() -> Bool {
        guard let au = audioUnit, !isRunning else { return isRunning }
        let status = AudioOutputUnitStart(au)
        if status == noErr {
            isRunning = true
            return true
        } else {
            print("[AudioCaptureUnit] Ошибка старта: \(status)")
            return false
        }
    }
    
    public func stop() {
        guard let au = audioUnit, isRunning else { return }
        AudioOutputUnitStop(au)
        isRunning = false
        peakLevelL = 0.0
        peakLevelR = 0.0
    }
    
    private func destroyAudioUnit() {
        if let au = audioUnit {
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            audioUnit = nil
        }
    }
}
