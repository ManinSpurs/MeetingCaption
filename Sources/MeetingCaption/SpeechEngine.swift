import Foundation
import Speech
import AVFoundation
import CoreAudio
import AudioCaptureBridge
import ScreenCaptureKit
import CaptionCore

struct AppFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum MicrophoneInput {
    static func defaultDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr else { throw AppFailure("마이크 입력 장치를 확인하지 못했습니다: \(status)") }
        return device
    }

    static func validate(deviceID: AudioDeviceID, format: AVAudioFormat) throws {
        // AVAudioEngine may report a positive placeholder format with no input device.
        guard deviceID != kAudioObjectUnknown, format.sampleRate > 0, format.channelCount > 0 else {
            throw AppFailure("사용할 수 있는 마이크를 찾지 못했습니다. 시스템 설정 > 사운드 > 입력에서 마이크를 선택해 주세요.")
        }
    }
}

struct SpeechPacket: Sendable {
    var captions: [Caption]
    var text: String
    var isFinal: Bool
}

// All audio conversion runs on one queue; buffers are copied before a capture callback returns.
final class AudioFeeder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MeetingCaption.audio-conversion", qos: .userInitiated)
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var previousInputEnd: Double?
    private var nextFrame: Int64 = 0
    private let offset: Double
    private let failure: @Sendable (String) -> Void
    private let recorder: AudioSegmentWriter?

    init(target: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
         offset: Double, recorder: AudioSegmentWriter? = nil, failure: @escaping @Sendable (String) -> Void) {
        self.target = target
        self.continuation = continuation
        self.offset = offset
        self.recorder = recorder
        self.failure = failure
    }

    func append(_ buffer: AVAudioPCMBuffer, timestamp: Double) {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
        copy.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<min(src.count, dst.count) {
            if let from = src[i].mData, let to = dst[i].mData {
                memcpy(to, from, Int(src[i].mDataByteSize))
            }
        }
        queue.async { [self] in
            guard let continuation else { return }
            if previousInputEnd == nil { nextFrame = Int64((offset * target.sampleRate).rounded()) }
            let gap = previousInputEnd.map { max(0, timestamp - $0) } ?? 0
            previousInputEnd = timestamp + Double(copy.frameLength) / copy.format.sampleRate
            if sourceFormat != copy.format {
                sourceFormat = copy.format
                converter = AVAudioConverter(from: copy.format, to: target)
            }
            guard let converter else { fail("오디오 형식을 변환할 수 없습니다."); return }
            let capacity = AVAudioFrameCount(ceil(Double(copy.frameLength) * target.sampleRate / copy.format.sampleRate)) + 64
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
                if supplied { outStatus.pointee = .noDataNow; return nil }
                supplied = true
                outStatus.pointee = .haveData
                return copy
            }
            if status == .error { fail(conversionError?.localizedDescription ?? "오디오 변환 오류"); return }
            guard converted.frameLength > 0 else { return }
            // A resampler retains samples between callbacks. Keep its output contiguous and
            // preserve only real capture-clock gaps, not converter latency.
            let startFrame = nextFrame + (gap > 0.02 ? Int64((gap * target.sampleRate).rounded()) : 0)
            nextFrame = startFrame + Int64(converted.frameLength)
            // The recording gets exactly the recognizer's frames at the recognizer's positions.
            recorder?.append(converted, atFrame: startFrame)
            let input = AnalyzerInput(buffer: converted, bufferStartTime: CMTime(value: startFrame, timescale: Int32(target.sampleRate)))
            if case .dropped = continuation.yield(input) {
                fail("음성인식이 입력 속도를 따라가지 못했습니다. 자막을 저장한 뒤 다시 시작해 주세요.")
            }
        }
    }

    private func fail(_ message: String) {
        continuation?.finish()
        continuation = nil
        failure(message)
    }

    func finish() async {
        await withCheckedContinuation { done in
            queue.async { [self] in
                if let converter, let continuation {
                    for _ in 0..<16 {
                        guard let tail = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else { break }
                        var error: NSError?
                        let status = converter.convert(to: tail, error: &error) { _, state in
                            state.pointee = .endOfStream
                            return nil
                        }
                        if status == .error { fail(error?.localizedDescription ?? "오디오 마무리 오류"); break }
                        if tail.frameLength > 0 {
                            let input = AnalyzerInput(buffer: tail, bufferStartTime: CMTime(value: nextFrame, timescale: Int32(target.sampleRate)))
                            recorder?.append(tail, atFrame: nextFrame)
                            nextFrame += Int64(tail.frameLength)
                            if case .dropped = continuation.yield(input) { fail("음성 입력 버퍼가 가득 찼습니다."); break }
                        }
                        if status == .endOfStream || tail.frameLength == 0 { break }
                    }
                }
                continuation?.finish()
                continuation = nil
                done.resume()
            }
        }
    }
}

final class ComputerAudio: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let feeder: AudioFeeder
    private let failed: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "MeetingCaption.system-audio", qos: .userInitiated)

    init(feeder: AudioFeeder, failed: @escaping @Sendable (String) -> Void) {
        self.feeder = feeder
        self.failed = failed
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw AppFailure("캡처할 디스플레이를 찾지 못했습니다.") }
        // System output includes other apps and WebKit's media helper processes.
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        stream = capture
        do { try await capture.startCapture() }
        catch { stream = nil; throw error }
    }

    func stop() async {
        let capture = stream
        stream = nil
        try? await capture?.stopCapture()
        await withCheckedContinuation { done in queue.async { done.resume() } }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { failed(error.localizedDescription) }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer),
              let description = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        pcm.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard status == noErr else { failed("컴퓨터 오디오 버퍼를 읽지 못했습니다: \(status)"); return }
        feeder.append(pcm, timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
    }
}

@MainActor
protocol MeetingSpeechEngine: AnyObject {
    var onPacket: (SpeechPacket) -> Void { get set }
    var onStatus: (String) -> Void { get set }
    var onFailure: (String) -> Void { get set }
    func startLive(source: String, localeID: String, offset: Double) async throws
    /// `recorder`, when given, receives every buffer handed to recognition.
    func startLive(source: String, localeID: String, offset: Double, recorder: AudioSegmentWriter?) async throws
    /// Starts recognizing an audio or video file from its beginning (caption time 0) and returns
    /// once reading has begun. `progress` receives the fraction of the file read so far.
    func startFile(url: URL, localeID: String, recorder: AudioSegmentWriter?,
                   progress: @escaping @Sendable (Double) -> Void) async throws
    /// Returns when the whole file has been recognized, or after `finish()` ended it early.
    func waitUntilFileEnds() async throws
    func finish() async throws
    func cancel() async
}

extension MeetingSpeechEngine {
    func startLive(source: String, localeID: String, offset: Double, recorder: AudioSegmentWriter?) async throws {
        try await startLive(source: source, localeID: localeID, offset: offset)
    }

    func startFile(url: URL, localeID: String, recorder: AudioSegmentWriter?,
                   progress: @escaping @Sendable (Double) -> Void) async throws {
        throw AppFailure("이 음성인식 엔진은 파일 받아쓰기를 지원하지 않습니다.")
    }

    func waitUntilFileEnds() async throws {}
}

@MainActor
final class AppleSpeechEngine: MeetingSpeechEngine {
    private var analyzer: SpeechAnalyzer?
    private var resultTask: Task<Void, Error>?
    private var feeder: AudioFeeder?
    private var microphone: AVAudioEngine?
    private var computer: ComputerAudio?
    private var fileSource: FileAudioSource?
    private var fileTask: Task<Void, Error>?
    private var reservedLocale: Locale?
    var onPacket: (SpeechPacket) -> Void = { _ in }
    var onStatus: (String) -> Void = { _ in }
    var onFailure: (String) -> Void = { _ in }

    func prepare(localeID: String) async throws -> (SpeechTranscriber, SpeechAnalyzer) {
        guard SpeechTranscriber.isAvailable else { throw AppFailure("이 Mac에서 애플 SpeechTranscriber를 사용할 수 없습니다.") }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            throw AppFailure("애플 음성인식이 선택한 언어를 지원하지 않습니다. 다른 언어를 선택해 주세요.")
        }
        let alreadyReserved = await AssetInventory.reservedLocales.contains(locale)
        if !alreadyReserved {
            guard try await AssetInventory.reserve(locale: locale) else { throw AppFailure("음성 모델을 예약할 수 없습니다. 설치된 다른 언어 모델을 확인해 주세요.") }
            reservedLocale = locale
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        if await AssetInventory.status(forModules: [transcriber]) != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onStatus("애플 음성 모델을 다운로드하고 있습니다. 처음 한 번은 인터넷이 필요합니다.")
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        return (transcriber, analyzer)
    }

    private func listen(to transcriber: SpeechTranscriber) {
        resultTask = Task { [weak self] in
            for try await result in transcriber.results {
                try Task.checkCancellation()
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let cues = Self.captions(from: result)
                self?.onPacket(SpeechPacket(captions: cues, text: text, isFinal: result.isFinal))
            }
        }
    }

    private static func captions(from result: SpeechTranscriber.Result) -> [Caption] {
        var cues: [Caption] = []
        var text = ""
        var start: Double?
        var end = 0.0
        for run in result.text.runs {
            let fragment = String(result.text[run.range].characters)
            text += fragment
            if let time = run.audioTimeRange {
                if start == nil { start = time.start.seconds }
                end = max(end, CMTimeRangeGetEnd(time).seconds)
            }
            if text.rangeOfCharacter(from: .alphanumerics) != nil &&
                (text.count >= 85 || end - (start ?? end) >= 6 || text.trimmingCharacters(in: .whitespaces).last.map({ ".!?。！？".contains($0) }) == true) {
                cues.append(Caption(start: start ?? result.range.start.seconds, end: end, text: text))
                text = ""
                start = nil
            }
        }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if text.rangeOfCharacter(from: .alphanumerics) == nil && !cues.isEmpty {
                cues[cues.count - 1].text += text
            } else {
                cues.append(Caption(start: start ?? result.range.start.seconds, end: max(end, CMTimeRangeGetEnd(result.range).seconds), text: text))
            }
        }
        if cues.isEmpty {
            cues = [Caption(start: result.range.start.seconds, end: CMTimeRangeGetEnd(result.range).seconds, text: String(result.text.characters))]
        }
        return cues.filter { !$0.text.isEmpty }
    }

    func startLive(source: String, localeID: String, offset: Double) async throws {
        try await startLive(source: source, localeID: localeID, offset: offset, recorder: nil)
    }

    func startLive(source: String, localeID: String, offset: Double, recorder: AudioSegmentWriter?) async throws {
        if source == "microphone" {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else { throw AppFailure("마이크 권한이 필요합니다. 시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 MeetingCaption을 허용해 주세요.") }
        }
        onStatus("애플 음성인식을 준비하고 있습니다.")
        let (transcriber, analyzer) = try await prepare(localeID: localeID)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AppFailure("음성인식용 오디오 형식을 찾지 못했습니다.")
        }
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(512))
        let fail: @Sendable (String) -> Void = { [weak self] message in Task { @MainActor in self?.onFailure(message) } }
        let feed = AudioFeeder(target: format, continuation: continuation, offset: offset, recorder: recorder, failure: fail)
        feeder = feed
        listen(to: transcriber)
        try await analyzer.start(inputSequence: stream)
        if source == "microphone" {
            let deviceID = try MicrophoneInput.defaultDeviceID()
            let audio = AVAudioEngine()
            let input = audio.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            try MicrophoneInput.validate(deviceID: deviceID, format: input.inputFormat(forBus: 0))
            try MicrophoneInput.validate(deviceID: deviceID, format: inputFormat)
            let tap: AVAudioNodeTapBlock = { buffer, when in
                let timestamp = when.isSampleTimeValid ? Double(when.sampleTime) / inputFormat.sampleRate : ProcessInfo.processInfo.systemUptime
                feed.append(buffer, timestamp: timestamp)
            }
            try MCAudioTap.installInputTap(input, format: inputFormat, block: tap)
            microphone = audio
            audio.prepare()
            try audio.start()
        } else {
            let capture = ComputerAudio(feeder: feed, failed: fail)
            computer = capture
            do { try await capture.start() }
            catch {
                await capture.stop()
                throw AppFailure("컴퓨터 소리 캡처를 시작하지 못했습니다. 시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹음에서 MeetingCaption을 허용한 뒤 다시 실행해 주세요.\n\(error.localizedDescription)")
            }
        }
        // Observe failures even when the user has not pressed Stop.
        if let task = resultTask {
            Task { [weak self] in
                do { try await task.value }
                catch is CancellationError { }
                catch { self?.onFailure(error.localizedDescription) }
            }
        }
        onStatus("인식 중입니다. 자막은 계속 누적됩니다.")
    }

    func startFile(url: URL, localeID: String, recorder: AudioSegmentWriter?,
                   progress: @escaping @Sendable (Double) -> Void) async throws {
        onStatus("애플 음성인식을 준비하고 있습니다.")
        let (transcriber, analyzer) = try await prepare(localeID: localeID)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AppFailure("음성인식용 오디오 형식을 찾지 못했습니다.")
        }
        try await analyzer.prepareToAnalyze(in: format)
        let source = try await FileAudioSource(url: url, target: format, recorder: recorder, progress: progress)
        fileSource = source
        listen(to: transcriber)
        let results = resultTask
        // The recognizer pulls each chunk when it is ready for it, so a long file is read at
        // the recognizer's pace.
        let input = AsyncStream<AnalyzerInput>(unfolding: { source.next() })
        fileTask = Task {
            _ = try await analyzer.analyzeSequence(input)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await results?.value
            if let message = source.failure { throw AppFailure("파일을 끝까지 읽지 못했습니다: \(message)") }
        }
    }

    func waitUntilFileEnds() async throws {
        try await fileTask?.value
    }

    func finish() async throws {
        if let source = fileSource {
            // Everything read so far is still recognized; nothing more is read.
            source.stop()
            fileSource = nil
            let reading = fileTask
            fileTask = nil
            do {
                try await reading?.value
                await release()
            } catch {
                await cancel()
                throw error
            }
            return
        }
        if let audio = microphone {
            audio.inputNode.removeTap(onBus: 0)
            audio.stop()
            microphone = nil
        }
        await computer?.stop()
        computer = nil
        await feeder?.finish()
        feeder = nil
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
            try await resultTask?.value
            await release()
        } catch {
            await cancel()
            throw error
        }
    }

    func cancel() async {
        if let audio = microphone {
            audio.inputNode.removeTap(onBus: 0)
            audio.stop()
            microphone = nil
        }
        await computer?.stop()
        computer = nil
        await feeder?.finish()
        feeder = nil
        fileSource?.stop()
        fileSource = nil
        fileTask?.cancel()
        fileTask = nil
        await analyzer?.cancelAndFinishNow()
        resultTask?.cancel()
        await release()
    }

    private func release() async {
        analyzer = nil
        resultTask = nil
        if let locale = reservedLocale {
            _ = await AssetInventory.release(reservedLocale: locale)
            reservedLocale = nil
        }
    }
}
