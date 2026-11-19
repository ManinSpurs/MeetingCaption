import AVFoundation
import Foundation

/// Writes the audio handed to speech recognition into one AAC (.m4a) file.
///
/// Buffers arrive with their frame position on the recognizer's timeline; the file's first
/// frame is caption time `timelineStart`, and capture gaps are filled with silence, so a
/// caption time maps onto the file by plain subtraction. Encoding runs on its own queue, so a
/// slow disk never holds back recognition. The file is a fragmented MPEG-4: if the app ends
/// unexpectedly, everything up to the last fragment stays playable.
final class AudioSegmentWriter: @unchecked Sendable {
    let url: URL
    let timelineStart: Double
    static let fragmentSeconds = 5.0
    static let bitRatePerChannel = 32_000

    private let queue = DispatchQueue(label: "MeetingCaption.audio-recording", qos: .utility)
    private let onFailure: @Sendable (String) -> Void
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var format: AVAudioFormat?
    private var baseFrame: Int64 = 0
    private var writtenFrames: Int64 = 0
    /// Silence is queued as a frame count and made into samples only as the encoder takes them,
    /// so a long capture gap holds no audio memory.
    private enum Pending {
        case sample(CMSampleBuffer, frames: Int64)
        case silence(start: Int64, frames: Int64)
    }
    private var pending: [Pending] = []
    private var heldFrames: Int64 = 0
    private var peakHeldFrames: Int64 = 0
    private var failed = false
    private var finishing: ((Double?) -> Void)?
    private var completed = false
    private var completions = 0
    private var drainScheduled = false
    private let isReady: (AVAssetWriterInput) -> Bool

    init(url: URL, timelineStart: Double, onFailure: @escaping @Sendable (String) -> Void = { _ in },
         isReady: @escaping (AVAssetWriterInput) -> Bool = { $0.isReadyForMoreMediaData }) {
        self.url = url
        self.timelineStart = timelineStart
        self.onFailure = onFailure
        self.isReady = isReady
    }

    /// For tests: how often the file was completed, and the most audio frames ever held in memory.
    var diagnostics: (completions: Int, peakHeldFrames: Int64) {
        queue.sync { (completions, peakHeldFrames) }
    }

    /// `frame` is the buffer's first frame on the recognizer timeline at the buffer's rate.
    func append(_ buffer: AVAudioPCMBuffer, atFrame frame: Int64) {
        queue.async { [self] in
            guard !failed, finishing == nil, buffer.frameLength > 0 else { return }
            if writer == nil { guard setUp(buffer.format) else { return } }
            guard buffer.format == format else {
                fail("녹음 중 오디오 형식이 바뀌어 음성 녹음을 멈췄습니다. 자막 인식은 계속됩니다.")
                return
            }
            let position = frame - baseFrame
            if position > writtenFrames { appendSilence(position - writtenFrames) }
            let skip = max(0, writtenFrames - position)
            guard skip < Int64(buffer.frameLength) else { return }
            enqueue(buffer, from: AVAudioFrameCount(skip))
            drain()
        }
    }

    /// Completes the file and returns its playable length in seconds; nil means no file was
    /// left behind (nothing was recorded, or it could not be made playable and was deleted).
    func finish() async -> Double? {
        await withCheckedContinuation { done in
            queue.async { [self] in
                guard finishing == nil else { done.resume(returning: nil); return }
                finishing = { done.resume(returning: $0) }
                drain()
            }
        }
    }

    /// Completes and deletes the file: used when the recording session never really started.
    func discard() async {
        _ = await finish()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Queue-confined

    private func setUp(_ format: AVAudioFormat) -> Bool {
        do {
            try? FileManager.default.removeItem(at: url)
            let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
            writer.movieFragmentInterval = CMTime(seconds: Self.fragmentSeconds, preferredTimescale: 600)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: Self.bitRatePerChannel * Int(format.channelCount)
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            self.input = input
            self.format = format
            baseFrame = Int64((timelineStart * format.sampleRate).rounded())
            return true
        } catch {
            fail("음성 녹음 파일을 만들지 못했습니다. 자막 인식은 계속됩니다: \(error.localizedDescription)")
            return false
        }
    }

    private func appendSilence(_ frames: Int64) {
        guard frames > 0 else { return }
        pending.append(.silence(start: writtenFrames, frames: frames))
        writtenFrames += frames
    }

    /// At most one second of silence, as a sample at timeline frame `start`.
    private func silenceSample(at start: Int64, frames: Int64) -> CMSampleBuffer? {
        guard let format else { return nil }
        let count = AVAudioFrameCount(frames)
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
            fail("음성 녹음 버퍼를 만들지 못했습니다. 자막 인식은 계속됩니다.")
            return nil
        }
        silence.frameLength = count
        for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        return makeSample(silence, count: count, at: start)
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer, from skip: AVAudioFrameCount) {
        guard let format else { return }
        let count = buffer.frameLength - skip
        let source: AVAudioPCMBuffer
        if skip == 0 {
            source = buffer
        } else {
            guard let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return }
            tail.frameLength = count
            let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
            let from = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let to = UnsafeMutableAudioBufferListPointer(tail.mutableAudioBufferList)
            for i in 0..<min(from.count, to.count) {
                if let src = from[i].mData, let dst = to[i].mData {
                    memcpy(dst, src.advanced(by: Int(skip) * bytesPerFrame), Int(count) * bytesPerFrame)
                }
            }
            source = tail
        }
        guard let sample = makeSample(source, count: count, at: writtenFrames) else { return }
        pending.append(.sample(sample, frames: Int64(count)))
        writtenFrames += Int64(count)
        heldFrames += Int64(count)
        peakHeldFrames = max(peakHeldFrames, heldFrames)
    }

    private func makeSample(_ source: AVAudioPCMBuffer, count: AVAudioFrameCount, at start: Int64) -> CMSampleBuffer? {
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
                                        presentationTimeStamp: CMTime(value: start, timescale: CMTimeScale(format.sampleRate)),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        var status = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                          makeDataReadyCallback: nil, refcon: nil,
                                          formatDescription: format.formatDescription,
                                          sampleCount: CMItemCount(count), sampleTimingEntryCount: 1,
                                          sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                                          sampleSizeArray: nil, sampleBufferOut: &sample)
        if status == noErr, let sample {
            // Copies the samples, so the recognizer's buffer is only read.
            status = CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
                                                                    blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                                    flags: 0, bufferList: source.audioBufferList)
        }
        guard status == noErr, let sample else {
            fail("음성 녹음 버퍼를 만들지 못했습니다(\(status)). 자막 인식은 계속됩니다.")
            return nil
        }
        return sample
    }

    private func drain() {
        if let input, !failed {
            let chunk = Int64(format?.sampleRate.rounded() ?? 16_000)
            writing: while let first = pending.first, isReady(input) {
                let sample: CMSampleBuffer
                switch first {
                case let .sample(buffer, frames):
                    pending.removeFirst()
                    heldFrames -= frames
                    sample = buffer
                case let .silence(start, frames):
                    let count = min(frames, chunk)
                    guard let silence = silenceSample(at: start, frames: count) else { break writing }
                    if count == frames { pending.removeFirst() }
                    else { pending[0] = .silence(start: start + count, frames: frames - count) }
                    sample = silence
                }
                guard !failed else { break }
                guard input.append(sample) else {
                    fail("음성 녹음 파일에 쓰지 못했습니다. 자막 인식은 계속됩니다: \(writer?.error?.localizedDescription ?? "")")
                    break
                }
            }
            if !pending.isEmpty && !failed {
                // The encoder is briefly behind; retry shortly rather than block the queue.
                if !drainScheduled {
                    drainScheduled = true
                    queue.asyncAfter(deadline: .now() + 0.02) { [self] in
                        drainScheduled = false
                        drain()
                    }
                }
                return
            }
        }
        // A retry queued before finish() can drain after completion already started.
        guard let done = finishing, !completed else { return }
        completed = true
        completions += 1
        complete(done)
    }

    private func complete(_ done: @escaping (Double?) -> Void) {
        guard let writer, let input, let format else {
            done(nil)
            return
        }
        let frames = writtenFrames
        let finished: (Bool) -> Void = { [self] completed in
            if completed && !failed && frames > 0 {
                done(Double(frames) / format.sampleRate)
            } else if let length = AudioFileProbe.duration(url), length > 0 {
                // Writing stopped early, but the fragments written so far still play.
                done(length)
            } else {
                try? FileManager.default.removeItem(at: url)
                done(nil)
            }
        }
        guard writer.status == .writing else {
            finished(false)
            return
        }
        input.markAsFinished()
        writer.finishWriting { [self] in
            queue.async { finished(writer.status == .completed) }
        }
    }

    private func fail(_ message: String) {
        guard !failed else { return }
        failed = true
        pending.removeAll()
        heldFrames = 0
        onFailure(message)
    }
}

enum AudioFileProbe {
    /// Playable length of an audio file in seconds, or nil when it cannot be read.
    static func duration(_ url: URL) -> Double? {
        guard FileManager.default.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
