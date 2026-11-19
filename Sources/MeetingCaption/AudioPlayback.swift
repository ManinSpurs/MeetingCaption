import AVFoundation
import CaptionCore
import Combine
import Foundation
import SwiftUI

/// Plays a record's audio segments in order. Positions are reported as (segment, offset);
/// `AudioTimeline` turns them into caption times.
@MainActor
final class AudioPlaybackController: ObservableObject {
    static let rates: [Float] = [0.75, 1, 1.25, 1.5]

    @Published private(set) var segments: [AudioSegment] = []
    @Published private(set) var segmentIndex = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime = 0.0
    @Published private(set) var duration = 0.0
    @Published var rate: Float = 1 {
        didSet { if isPlaying { player.rate = rate } }
    }
    /// Called with (segment index, offset) whenever the position moves.
    var onPosition: (Int, Double) -> Void = { _, _ in }

    private let player = AVPlayer()
    private var urls: [URL] = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadedIndex: Int?

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    var hasAudio: Bool { !segments.isEmpty }

    /// Replaces the playable audio, stopping whatever was playing.
    func load(_ segments: [AudioSegment], record: URL?) {
        // Segments and their files stay index-aligned: a segment without a valid file is dropped.
        let pairs = record.map { r in segments.compactMap { s in RecordAudio.url(of: s, record: r).map { (s, $0) } } } ?? []
        let segments = pairs.map(\.0)
        let newURLs = pairs.map(\.1)
        guard segments != self.segments || newURLs != urls else { return }
        stop()
        self.segments = segments
        urls = newURLs
        segmentIndex = 0
        currentTime = 0
        duration = segments.first.map { ($0.end ?? $0.start) - $0.start } ?? 0
        loadedIndex = nil
        player.replaceCurrentItem(with: nil)
    }

    func play(segment index: Int, at offset: Double) {
        guard segments.indices.contains(index) else { return }
        select(index)
        let time = CMTime(seconds: max(0, offset), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = max(0, offset)
        player.playImmediately(atRate: rate)
        isPlaying = true
        onPosition(index, currentTime)
    }

    func togglePlay() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else if hasAudio {
            play(segment: segmentIndex, at: currentTime >= duration - 0.05 ? 0 : currentTime)
        }
    }

    func seek(to offset: Double) {
        guard hasAudio else { return }
        select(segmentIndex)
        currentTime = min(max(0, offset), duration)
        player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        onPosition(segmentIndex, currentTime)
    }

    func stop() {
        player.pause()
        isPlaying = false
    }

    private func select(_ index: Int) {
        guard loadedIndex != index || player.currentItem == nil, urls.indices.contains(index) else { return }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        let item = AVPlayerItem(url: urls[index])
        // Speech stays intelligible and at its natural pitch at every speed.
        item.audioTimePitchAlgorithm = .timeDomain
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reachedEnd() }
        }
        loadedIndex = index
        segmentIndex = index
        duration = segments[index].end.map { $0 - segments[index].start } ?? 0
    }

    /// While the scrubber is dragged, the knob follows the hand; the seek happens on release.
    var isScrubbing = false {
        didSet { if oldValue && !isScrubbing { seek(to: currentTime) } }
    }

    func scrub(to offset: Double) {
        currentTime = min(max(0, offset), duration)
    }

    private func tick(_ seconds: Double) {
        guard isPlaying, !isScrubbing, seconds.isFinite else { return }
        // A segment's caption range can end before its file does (the session's tail after the
        // last sentence); the scrubber spans the whole file.
        if let length = player.currentItem?.duration.seconds, length.isFinite, length > 0 { duration = length }
        currentTime = min(seconds, duration)
        onPosition(segmentIndex, currentTime)
    }

    /// The next recording session continues where this one ended.
    private func reachedEnd() {
        if segmentIndex + 1 < segments.count {
            play(segment: segmentIndex + 1, at: 0)
        } else {
            isPlaying = false
            currentTime = duration
        }
    }
}

/// Compact controls for the open record's audio: play/pause, scrubber, time and speed.
struct AudioPlaybackBar: View {
    @ObservedObject var player: AudioPlaybackController

    var body: some View {
        HStack(spacing: 10) {
            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .help(player.isPlaying ? "일시 정지" : "재생")
            Text(Self.clock(player.currentTime))
                .font(.caption.monospacedDigit())
            Slider(value: Binding(get: { player.currentTime }, set: { player.scrub(to: $0) }),
                   in: 0...max(player.duration, 0.1)) { editing in
                player.isScrubbing = editing
            }
            .controlSize(.small)
            Text(Self.clock(player.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if player.segments.count > 1 {
                Text("녹음 \(player.segmentIndex + 1)/\(player.segments.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("이 기록은 여러 번 나누어 녹음되었습니다. 한 구간이 끝나면 다음 구간을 이어서 재생합니다.")
            }
            Picker("속도", selection: $player.rate) {
                ForEach(AudioPlaybackController.rates, id: \.self) { rate in
                    Text(Self.rateLabel(rate)).tag(rate)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("재생 속도")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func rateLabel(_ rate: Float) -> String {
        (rate == rate.rounded() ? String(format: "%.0f", rate) : String(format: "%g", rate)) + "×"
    }
}
