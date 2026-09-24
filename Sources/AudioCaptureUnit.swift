import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

public final class AudioCaptureUnit {
    private var audioUnit: AudioComponentInstance?
    private let leftRingBuffer: AudioRingBuffer
    private let rightRingBuffer: AudioRingBuffer
    
    public private(set) var isRunning: Bool = false
    public private(set) var sampleRate: Double = 44100.0
    public private(set) var peakLevelL: Float = 0.0
    public private(set) var peakLevelR: Float = 0.0
    private var currentDeviceID: AudioDeviceID?
    
    // Предвыделенные статические буферы для исключения malloc в аудиопотоке
    private static let maxFrames = 4096
    private var leftScratch = [Float](repeating: 0, count: maxFrames)
    private var rightScratch = [Float](repeating: 0, count: maxFrames)
    private let ablPointer: UnsafeMutableAudioBufferListPointer = AudioBufferList.allocate(maximumBuffers: 2)
    
    // Вспомогательный контекст
    private final class Context {
        var captureUnit: AudioCaptureUnit?
    }
    private var context = Context()
    
    public init(leftRingBuffer: AudioRingBuffer, rightRingBuffer: AudioRingBuffer) {
        self.leftRingBuffer = leftRingBuffer
        self.rightRingBuffer = rightRingBuffer
        self.context.captureUnit = self
    }
    
    deinit {
        stop()
        destroyAudioUnit()
        free(UnsafeMutableRawPointer(ablPointer.unsafeMutablePointer))
    }
    
    public func setup(deviceID: AudioDeviceID, sampleRate: Double = 44100.0) -> Bool {
        stop()
        destroyAudioUnit()
        
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
                            unit.leftRingBuffer.write(lPtr.baseAddress!, count: frames)
                            unit.rightRingBuffer.write(rPtr.baseAddress!, count: frames)
                            
                            var maxL: Float = 0.0
                            var maxR: Float = 0.0
                            for i in 0..<frames {
                                let l = abs(lPtr[i])
                                let r = abs(rPtr[i])
                                if l > maxL { maxL = l }
                                if r > maxR { maxR = r }
                            }
                            unit.peakLevelL = max(unit.peakLevelL * 0.9, maxL)
                            unit.peakLevelR = max(unit.peakLevelR * 0.9, maxR)
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
