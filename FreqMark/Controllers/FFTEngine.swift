import Foundation
import AVFoundation
import Accelerate

// AudioDeviceDescriptor is defined in Models/StateStore.swift

// MARK: - FFTEngine: AUHAL capture + vDSP FFT
//
// Capture goes through AUHAL (kAudioUnitSubType_HALOutput) rather than
// AVCaptureSession: AVFoundation audio-only sessions on macOS can start with
// zero callbacks, while AUHAL is the canonical API for targeting a *specific*
// input device (SSL 12 etc). Devices are identified by CoreAudio UIDs.

final class FFTEngine: NSObject, ObservableObject {
    static let frameSize = 2048
    static let hopSize = 1024   // 50% overlap: 0.7s→ windowed FFTs move smoothly
    static let logPoints = 512
    static let waveformSamples = 512

    @Published var spectrum: [Float] = Array(repeating: 0, count: logPoints)
    /// Un-normalized log-grid values (0..1 relative to frame peak) for the dB readout
    @Published var rawSpectrum: [Float] = Array(repeating: 1, count: logPoints)
    @Published var rollingSamples: [Float] = Array(repeating: 0, count: waveformSamples)
    @Published var isRunning = false
    @Published var permissionStatus: String = "unknown"
    @Published var debugInfo: String = ""
    @Published var deviceSampleRate: Double = 0

    private(set) var logFrequencies: [Double] = []

    // vDSP FFT state
    private let halfBins = FFTEngine.frameSize / 2
    private var fftSetup: FFTSetup?
    private var window: [Float] = []
    private var windowedReal: [Float] = []
    private var windowedImag: [Float] = []
    private var magnitudes: [Float] = []

    // AUHAL state
    fileprivate var audioUnit: AudioUnit?
    private let renderQueue = DispatchQueue(label: "FreqMark.render", qos: .userInteractive)
    private var selectedDeviceUID: String?
    var permissionJustRequested = false

    private var sampleFIFO: [Float] = []
    private var callbackCount = 0
    private var recentPeak: Float = 0
    private var restartAttempts = 0

    override init() {
        super.init()
        buildWindowAndFFT()
        buildLogFrequencyMap(sampleRate: 48000)
    }

    deinit {
        stopCapture()
    }

    // MARK: Window/FFT construction

    private func buildWindowAndFFT() {
        let n = FFTEngine.frameSize
        window = Array(unsafeUninitializedCapacity: n) { buf, count in
            for i in 0..<n {
                let t = Float(i) / Float(n - 1)
                buf[i] = 0.5 * (1 - cos(2 * Float.pi * t))
            }
            count = n
        }
        windowedReal = Array(repeating: 0, count: halfBins)
        windowedImag = Array(repeating: 0, count: halfBins)
        magnitudes = Array(repeating: 0, count: halfBins)
        let log2n = vDSP_Length(log2(Double(n)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }

    private func buildLogFrequencyMap(sampleRate rate: Double) {
        let minFreq = 20.0
        let maxFreq = rate / 2 * 0.95
        logFrequencies = (0..<FFTEngine.logPoints).map { i in
            let t = Double(i) / Double(FFTEngine.logPoints - 1)
            return minFreq * pow(maxFreq / minFreq, t)
        }
    }

    // MARK: Device enumeration (CoreAudio, so IDs match AUHAL)

    static func listInputDevices() -> [AudioDeviceDescriptor] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }

        var out: [AudioDeviceDescriptor] = []
        for id in ids {
            var inAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var inSize: UInt32 = 0
            if AudioObjectGetPropertyDataSize(id, &inAddr, 0, nil, &inSize) == noErr && inSize > 0 {
                if let name = deviceStringProperty(id, kAudioObjectPropertyName),
                   let uid = deviceStringProperty(id, kAudioDevicePropertyDeviceUID) {
                    out.append(AudioDeviceDescriptor(id: uid, name: name))
                }
            }
        }
        return out
    }

    fileprivate static func deviceStringProperty(_ deviceID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfString: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &cfString) == noErr else { return nil }
        return cfString as String?
    }

    // MARK: Device selection

    func useDevice(id: String) {
        selectedDeviceUID = id
        UserDefaults.standard.set(id, forKey: "freqmark.inputDeviceID")
        if isRunning || permissionJustRequested {
            requestStart(deviceUID: id)
        }
    }

    /// Resolves a UID -> AudioObjectID. Falls back to the system default input.
    private func resolveDeviceID(uid: String?) -> AudioObjectID? {
        guard let uid else { return defaultInputDeviceID() }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            if let dUID = FFTEngine.deviceStringProperty(id, kAudioDevicePropertyDeviceUID), dUID == uid {
                return id
            }
        }
        return defaultInputDeviceID()
    }

    private func defaultInputDeviceID() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    // MARK: Permission + lifecycle

    func requestPermissionThenStart() async {
        permissionJustRequested = true
        var granted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if !granted {
            granted = await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            }
        }
        await MainActor.run { permissionStatus = granted ? "granted" : "DENIED" }
        guard granted else {
            NSLog("FreqMark: microphone permission denied")
            return
        }
        await withCheckedContinuation { cont in
            requestStart(deviceUID: nil) { cont.resume() }
        }
    }

    /// All start/stop serialized so concurrent requests can't interleave, and
    /// @Published writes (isRunning, deviceSampleRate) happen on the main
    /// thread: a background publish deadlocks against SwiftUI's observer,
    /// which hops to main and re-locks (verified via sample: both threads
    /// parked on ObservableObjectPublisher's unfair lock).
    func requestStart(deviceUID: String?, then callback: (() -> Void)? = nil) {
        let perform: @Sendable (FFTEngine) -> Void = { engine in
            engine.performStartAUHAL()
        }
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.stopCapture()
            if let uid = deviceUID { self.selectedDeviceUID = uid }
            perform(self)
            if let callback { DispatchQueue.main.async(execute: callback) }
        }
    }

    /// Public no-arg start (toolbar play button).
    func startCapture() {
        requestStart(deviceUID: nil)
    }

    private func performStartAUHAL() {
        var component = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &component) else {
            NSLog("FreqMark: AUHAL component not found")
            return
        }
        var au: AudioUnit?
        guard AudioComponentInstanceNew(comp, &au) == noErr, let audioUnit = au else {
            NSLog("FreqMark: cannot create AUHAL instance")
            return
        }

        // Enable input on element 1, disable output on element 0
        var enableInput: UInt32 = 1
        AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableInput, UInt32(MemoryLayout<UInt32>.size))
        var disableOutput: UInt32 = 0
        AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disableOutput, UInt32(MemoryLayout<UInt32>.size))

        // Target the chosen device
        guard let deviceID = resolveDeviceID(uid: selectedDeviceUID) else {
            NSLog("FreqMark: no input device to target")
            AudioComponentInstanceDispose(audioUnit)
            return
        }
        var devID = deviceID
        let devSet = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &devID, UInt32(MemoryLayout<AudioObjectID>.size))
        if devSet != noErr {
            NSLog("FreqMark: cannot set CurrentDevice (\(devSet))")
            AudioComponentInstanceDispose(audioUnit)
            return
        }

        guard AudioUnitInitialize(audioUnit) == noErr else {
            NSLog("FreqMark: AudioUnitInitialize failed")
            AudioComponentInstanceDispose(audioUnit)
            return
        }

        // Native device rate for the log grid
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var deviceASBD = AudioStreamBasicDescription()
        AudioUnitGetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &deviceASBD, &asbdSize)
        let nativeRate = deviceASBD.mSampleRate > 0 ? deviceASBD.mSampleRate : 48000

        var monoFormat = AudioStreamBasicDescription()
        monoFormat.mSampleRate = nativeRate
        monoFormat.mFormatID = kAudioFormatLinearPCM
        monoFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        monoFormat.mBytesPerPacket = 4
        monoFormat.mFramesPerPacket = 1
        monoFormat.mBytesPerFrame = 4
        monoFormat.mChannelsPerFrame = 1
        monoFormat.mBitsPerChannel = 32
        monoFormat.mReserved = 0
        let setFmt = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &monoFormat, asbdSize)
        if setFmt != noErr {
            NSLog("FreqMark: cannot set client stream format (\(setFmt))")
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
            return
        }

        // Input callback on element 1
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var callbackStruct = AURenderCallbackStruct(
            inputProc: freqMarkRenderCallback,
            inputProcRefCon: selfPtr)
        AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        guard AudioOutputUnitStart(audioUnit) == noErr else {
            NSLog("FreqMark: AudioOutputUnitStart failed")
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
            return
        }

        self.audioUnit = audioUnit
        sampleFIFO.removeAll()
        processedCount = 0
        callbackCount = 0
        displayedDB = Array(repeating: -Float(minDB), count: FFTEngine.logPoints)
        // Async publish to main — NEVER sync from the render queue: this queue
        // runs at user-interactive priority, and main may be busy in a picker
        // menu event loop or draining a FFT backlog; a sync here is a
        // priority-inversion deadlock (verified hang: render blocked on main,
        // main in menu tracking + backlog drain → beach ball on every switch).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.deviceSampleRate = nativeRate
            self.buildLogFrequencyMap(sampleRate: nativeRate)
            if self.audioUnit != nil { // still current; a newer switch may have won
                self.isRunning = true
            }
        }
        NSLog("FreqMark: AUHAL capture started deviceID=\(deviceID) rate=\(nativeRate)")

        // Watchdog: a device that starts but never delivers callbacks (dead
        // stream after a switch) gets exactly one automatic restart.
        restartAttempts += 1
        let gen = restartAttempts
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.restartAttempts == gen, self.isRunning, self.callbackCount == 0 else { return }
            NSLog("FreqMark: watchdog restart — no callbacks from deviceID=\(deviceID)")
            self.requestStart(deviceUID: nil)
        }
    }

    func stopCapture() {
        if let au = audioUnit {
            AudioOutputUnitStop(au)
            audioUnit = nil
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
        }
        // Async, not sync: this can run on the render queue, and syncing to
        // main from a high-priority queue while main is busy = deadlock.
        if Thread.isMainThread {
            isRunning = false
        } else {
            DispatchQueue.main.async { [weak self] in self?.isRunning = false }
        }
    }

    func stop() {
        stopCapture()
    }

    // MARK: Audio processing — FFT runs OFF main (it jams the UI), only the
    // final published values hop to main.

    fileprivate func handleSamples(_ block: [Float], sampleRate: Double) {
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.processSamples(block, sampleRate: sampleRate)
        }
    }

    /// Runs on renderQueue. Computes everything, then publishes final values
    /// to main in one cheap async hop (a couple of array copies — no FFT).
    private func processSamples(_ block: [Float], sampleRate: Double) {
        guard !block.isEmpty else { return }
        let rateChanged = abs(deviceSampleRate - sampleRate) > 0.5 && sampleRate > 0

        // Rolling waveform + counters in render-queue-local storage — writing
        // @Published here fires Combine synchronously on THIS thread and
        // deadlocks against main (verified hang: both threads parked on the
        // publisher's unfair lock through rollingSamples.setter).
        let tail = block.suffix(FFTEngine.waveformSamples)
        waveBuffer.removeFirst(min(tail.count, waveBuffer.count))
        waveBuffer.append(contentsOf: tail)
        recentPeak = max(recentPeak * 0.98, block.map { abs($0) }.max() ?? 0)
        callbackCount += 1
        currentDebug = String(format: "cb=%d pk=%.4f", callbackCount, recentPeak)

        // FIFO accumulate to frameSize and run FFT every hopSize samples
        // (50% overlap) so the display refreshes ~2x smoother.
        sampleFIFO.append(contentsOf: block)
        processedCount += block.count
        while processedCount >= FFTEngine.hopSize {
            processedCount -= FFTEngine.hopSize
            if sampleFIFO.count >= FFTEngine.frameSize {
                let frame = Array(sampleFIFO.suffix(FFTEngine.frameSize))
                runFFT(on: frame, rateChanged: rateChanged, newRate: sampleRate)
            }
        }
    }

    private func runFFT(on frame: [Float], rateChanged: Bool = false, newRate: Double = 0) {
        guard let fftSetup, frame.count == FFTEngine.frameSize else { return }
        frame.withUnsafeBufferPointer { buf in
            guard let samples = buf.baseAddress else { return }
            var windowed = [Float](repeating: 0, count: FFTEngine.frameSize)
            vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(FFTEngine.frameSize))

            // Full-size split-complex buffers: vDSP_fft_zip requires TWO real
            // arrays each of frameSize (not frameSize/2) even for a forward
            // transform, or it overruns — this overruns crashed the app.
            var real = [Float](repeating: 0, count: FFTEngine.frameSize)
            var imag = [Float](repeating: 0, count: FFTEngine.frameSize)
            real.withUnsafeMutableBufferPointer { rptr in
                imag.withUnsafeMutableBufferPointer { iptr in
                    guard let rbase = rptr.baseAddress, let ibase = iptr.baseAddress else { return }
                    // real part = windowed signal; imag = 0
                    windowed.withUnsafeBufferPointer { wsrc in
                        if let wbase = wsrc.baseAddress {
                            rbase.initialize(from: wbase, count: FFTEngine.frameSize)
                        }
                    }
                    var split = DSPSplitComplex(realp: rbase, imagp: ibase)
                    vDSP_fft_zip(fftSetup, &split, 1, vDSP_Length(log2(Double(FFTEngine.frameSize))), FFTDirection(FFT_FORWARD))
                    // the magnitudes pointer MUST live inside its own closure:
                    // escaping it crashes on the next device switch (dangling
                    // interior pointer after the buffer scope ends).
                    magnitudes.withUnsafeMutableBufferPointer { mptr in
                        guard let mbase = mptr.baseAddress else { return }
                        vDSP_zvabs(&split, 1, mbase, 1, vDSP_Length(halfBins))
                    }
                }
            }

            // Resample to log grid, convert to dB, apply peak-decay ballistics.
            var magLog = magnitudes
            let rate = sampleRateForGrid()
            let dBGrid: [Float] = resampleToLog(bins: magLog, rate: rate).map { v in
                let rel = v / (magnitudes.max() ?? 1)
                return rel > 1e-9 ? 20 * log10(rel) : -minDB
            }
            let clamped = dBGrid.map { max($0, -minDB) }

            // Display smoothing: rise fast, fall slow (spectrum-analyzer ballistics)
            var out = displayedDB
            let dispMin: Float = -minDB
            for i in 0..<out.count {
                let target = clamped[i]
                if target > out[i] {
                    out[i] = target                                  // instant attack
                } else {
                    out[i] = max(dispMin, out[i] - dbDropPerSecond * Float(hopIntervalSeconds))
                }
            }
            displayedDB = out

            // Smoothing stack: 3-point moving average applied twice + octave-
            // band proportionality: high frequencies naturally wiggle more in
            // a log view, so average wider at high frequencies. Result: a
            // coherent "response curve" rather than a comb of FFT bins.
            var s1 = out
            for i in 1..<(out.count - 1) {
                s1[i] = out[i - 1] * 0.25 + out[i] * 0.5 + out[i + 1] * 0.25
            }
            var s2 = s1
            for i in 1..<(s1.count - 1) {
                s2[i] = s1[i - 1] * 0.35 + s1[i] * 0.3 + s1[i + 1] * 0.35
            }
            var smooth = s2
            let n = s2.count
            for i in 0..<n {
                // window half-width grows toward high end (log index space)
                let half = 2 + (i * 6) / n
                var acc: Float = 0
                var cnt: Float = 0
                for j in max(0, i - half)...min(n - 1, i + half) {
                    acc += s2[j]
                    cnt += 1
                }
                smooth[i] = i < 2 ? s2[i] : acc / cnt
            }
            displayedDB = smooth

            // Publish on a 0..1 scale = (dB + minDB) / minDB  (0 dB → 1, -minDB → 0)
            let lo = -minDB
            let norm = smooth.map { max(0, min(1, ($0 - lo) / (-lo))) }

            // All @Published writes happen on main — cheap copies only.
            let pubRaw = norm
            let pubSpectrum = norm
            let pubRate = rateChanged ? newRate : deviceSampleRate
            let rebuildGrid = rateChanged
            let pubWave = waveBuffer
            let pubDebug = currentDebug
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if rebuildGrid {
                    self.deviceSampleRate = pubRate
                    self.buildLogFrequencyMap(sampleRate: pubRate)
                }
                self.rollingSamples = pubWave
                self.debugInfo = pubDebug
                self.rawSpectrum = pubRaw
                self.spectrum = pubSpectrum
            }
        }
    }

    private var processedCount = 0
    /// Render-queue working copies — never @Published, never touched on main
    private var waveBuffer: [Float] = Array(repeating: 0, count: FFTEngine.waveformSamples)
    private var currentDebug = ""
    /// Spectrum analyzer ballistics: how fast traces fall, dB/sec
    private var dbDropPerSecond: Float = 18
    private var hopIntervalSeconds: Float { Float(FFTEngine.hopSize) / Float(max(1, sampleRateForGrid())) }
    /// Displayed dynamic range: floor of the graph
    private var minDB: Float = 80
    /// Smoothed display state (dB per log-grid point)
    private var displayedDB: [Float] = Array(repeating: -80, count: FFTEngine.logPoints)

    private func sampleRateForGrid() -> Double {
        deviceSampleRate > 0 ? deviceSampleRate : 48000
    }

    private func resampleToLog(bins: [Float], rate: Double) -> [Float] {
        var out = [Float](repeating: 0, count: FFTEngine.logPoints)
        for (i, f) in logFrequencies.enumerated() {
            let binFloat = f / rate * Double(FFTEngine.frameSize)
            let bin = min(Int(binFloat), halfBins - 1)
            let next = min(bin + 1, halfBins - 1)
            let frac = Float(binFloat - Double(bin))
            out[i] = max(0, bins[bin] + (bins[next] - bins[bin]) * frac)
        }
        return out
    }
}

// MARK: Realtime C callback (runs on CoreAudio's render thread)

private func freqMarkRenderCallback(
    _ inRefCon: UnsafeMutableRawPointer,
    _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
    _ inBusNumber: UInt32,
    _ inNumberFrames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {

    let engine = Unmanaged<FFTEngine>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let au = engine.audioUnit else { return -1 /* kAudioUnitErr_InvalidUnit */ }

    // Input callbacks receive nil ioData: provide our own mono ABL
    var monoASBD = AudioStreamBasicDescription()
    var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &monoASBD, &asbdSize)

    let frames = Int(inNumberFrames)
    var samples = [Float](repeating: 0, count: frames)
    // Build the AudioBufferList in raw memory: mBuffers is a flexible array
    // Swift can't subscript directly, but the first element sits right after
    // mNumberBuffers per the C layout (with pointer alignment padding).
    let ablPtr = UnsafeMutableRawPointer.allocate(
        byteCount: MemoryLayout<AudioBufferList>.size,
        alignment: MemoryLayout<UnsafeRawPointer>.alignment)
    defer { ablPtr.deallocate() }
    let abl = ablPtr.assumingMemoryBound(to: AudioBufferList.self)
    abl.pointee.mNumberBuffers = 1
    var firstBuffer = AudioBuffer()
    firstBuffer.mNumberChannels = 1
    firstBuffer.mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
    samples.withUnsafeMutableBufferPointer { ptr in
        firstBuffer.mData = ptr.baseAddress.map { UnsafeMutableRawPointer($0) }
    }
    let firstBufferOffset = MemoryLayout.offset(of: \AudioBufferList.mBuffers) ?? 8
    ablPtr.advanced(by: firstBufferOffset).assumingMemoryBound(to: AudioBuffer.self).pointee = firstBuffer

    let err = AudioUnitRender(au, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, abl)
    if err != noErr { return err }

    engine.handleSamples(samples, sampleRate: monoASBD.mSampleRate)
    return noErr
}
