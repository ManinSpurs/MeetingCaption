import AVFoundation
import Foundation
import Speech
import UniformTypeIdentifiers

/// Decodes the sound of an audio or video file into recognizer-format buffers, one chunk per
/// pull, so the recognizer sets the pace and a long file is never held in memory.
///
/// The file's first sample is caption time 0. Each chunk also goes to `recorder`, which gives
/// the record a compact copy laid out on exactly the times the captions carry.
final class FileAudioSource: @unchecked Sendable {
    /// What "파일 받아쓰기" accepts: any audio file, and the sound track of any movie.
    static let contentTypes: [UTType] = [.audio, .movie]

    /// Length of the file in seconds; 0 when the container does not say.
    let duration: Double

    private let reader: AVAssetReader
    private let output: AVAssetReaderAudioMixOutput
    private let target: AVAudioFormat
    private let decoded: AVAudioFormat
    private let converter: AVAudioConverter?
    private let recorder: AudioSegmentWriter?
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var stopped = false
    private var failureMessage: String?
    private var nextFrame: Int64 = 0
    private var reportedPercent = -1

    init(url: URL, target: AVAudioFormat, recorder: AudioSegmentWriter? = nil,
         progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do { tracks = try await asset.loadTracks(withMediaType: .audio) }
        catch { throw AppFailure("이 파일을 열지 못했습니다. 오디오 또는 동영상 파일인지 확인해 주세요.\n\(error.localizedDescription)") }
        guard !tracks.isEmpty else { throw AppFailure("이 파일에는 받아쓸 소리가 없습니다.") }
        let length = (try? await asset.load(.duration).seconds) ?? 0
        duration = length.isFinite ? max(0, length) : 0
        // The reader resamples and mixes down to one channel; only the sample type can still
        // differ from the recognizer's format.
        guard let decoded = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target.sampleRate,
                                          channels: 1, interleaved: false) else {
            throw AppFailure("음성인식용 오디오 형식을 만들지 못했습니다.")
        }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw AppFailure("이 파일을 읽지 못했습니다: \(error.localizedDescription)") }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: target.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AppFailure("이 파일의 소리 형식은 받아쓸 수 없습니다.") }
        reader.add(output)
        guard reader.startReading() else {
            throw AppFailure("이 파일을 읽지 못했습니다: \(reader.error?.localizedDescription ?? "알 수 없는 오류")")
        }
        self.reader = reader
        self.output = output
        self.target = target
        self.decoded = decoded
        self.converter = decoded == target ? nil : AVAudioConverter(from: decoded, to: target)
        self.recorder = recorder
        self.progress = progress
    }

    /// Why reading ended before the end of the file; nil when it reached the end or was stopped.
    var failure: String? {
        lock.lock(); defer { lock.unlock() }
        return failureMessage
    }

    /// Ends the input at the next pull, so everything already read is still recognized.
    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
    }

    /// The next chunk at its position on the caption timeline; nil at the end of the file,
    /// after `stop()`, or when decoding failed (see `failure`).
    func next() -> AnalyzerInput? {
        lock.lock()
        let halted = stopped
        lock.unlock()
        guard !halted else { return nil }
        while let sample = output.copyNextSampleBuffer() {
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0 else { continue }
            guard let pcm = AVAudioPCMBuffer(pcmFormat: decoded, frameCapacity: AVAudioFrameCount(frames)) else {
                return fail("오디오 버퍼를 만들지 못했습니다.")
            }
            pcm.frameLength = AVAudioFrameCount(frames)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                                       into: pcm.mutableAudioBufferList)
            guard status == noErr else { return fail("파일의 소리를 읽지 못했습니다: \(status)") }
            var buffer = pcm
            if let converter {
                guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: pcm.frameLength) else {
                    return fail("오디오 버퍼를 만들지 못했습니다.")
                }
                do { try converter.convert(to: converted, from: pcm) }
                catch { return fail("오디오 형식을 변환할 수 없습니다: \(error.localizedDescription)") }
                buffer = converted
            }
            let start = nextFrame
            nextFrame += Int64(buffer.frameLength)
            recorder?.append(buffer, atFrame: start)
            report()
            return AnalyzerInput(buffer: buffer, bufferStartTime: CMTime(value: start, timescale: Int32(target.sampleRate)))
        }
        if reader.status == .failed {
            return fail(reader.error?.localizedDescription ?? "파일을 끝까지 읽지 못했습니다.")
        }
        progress(1)
        return nil
    }

    private func fail(_ message: String) -> AnalyzerInput? {
        lock.lock(); defer { lock.unlock() }
        failureMessage = message
        return nil
    }

    /// Whole percents only, so a long file does not flood the main actor.
    private func report() {
        guard duration > 0 else { return }
        let fraction = min(1, Double(nextFrame) / target.sampleRate / duration)
        let percent = Int(fraction * 100)
        guard percent != reportedPercent else { return }
        reportedPercent = percent
        progress(fraction)
    }
}
