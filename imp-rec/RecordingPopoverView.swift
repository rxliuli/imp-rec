import AVFoundation
import SwiftUI
import VideoToolbox

// MARK: - Editor State

final class EditorState: ObservableObject {
    let videoURL: URL
    @Published var player: AVPlayer?
    @Published var duration: Double = 0
    @Published var currentTime: Double = 0
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    @Published var isPlaying = false
    @Published var isExporting = false
    var wasPlayingBeforeDrag = false

    private var alive = true
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    init(videoURL: URL) {
        self.videoURL = videoURL
        print("[EditorState] init for \(videoURL.lastPathComponent)")
    }

    deinit {
        print("[EditorState] deinit")
    }

    func setup() async {
        let player = AVPlayer(url: videoURL)
        player.actionAtItemEnd = .none
        self.player = player

        if let item = player.currentItem {
            let dur = try? await item.asset.load(.duration)
            if let dur, dur.isValid, !dur.isIndefinite {
                duration = dur.seconds
                trimEnd = dur.seconds
            }
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self, self.alive else { return }
            self.currentTime = time.seconds
            if self.isPlaying && time.seconds >= self.trimEnd {
                self.loopToStart()
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.alive, self.isPlaying else { return }
            self.loopToStart()
        }

        player.play()
        isPlaying = true
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= trimEnd || currentTime < trimStart {
                seekInternal(trimStart)
            }
            player.play()
            isPlaying = true
        }
    }

    func stepFrame(forward: Bool) {
        guard let player else { return }
        if isPlaying { player.pause(); isPlaying = false }
        let step = 1.0 / 30.0
        let t = forward ? currentTime + step : currentTime - step
        seekInternal(max(trimStart, min(trimEnd, t)))
    }

    func seek(to time: Double) {
        seekInternal(time)
    }

    func beginDrag() {
        wasPlayingBeforeDrag = isPlaying
        if isPlaying { player?.pause(); isPlaying = false }
    }

    func endDrag() {
        seekInternal(trimStart)
        player?.play()
        isPlaying = true
    }

    func cleanup() {
        alive = false
        if let o = timeObserver { player?.removeTimeObserver(o); timeObserver = nil }
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        player?.pause()
    }

    func exportVideo() async -> URL? {
        isExporting = true
        defer { isExporting = false }

        do {
            let moviesDir =
                FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("imp-rec", isDirectory: true)
            try FileManager.default.createDirectory(at: moviesDir, withIntermediateDirectories: true)

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let outputURL = moviesDir.appendingPathComponent(
                "imp-rec-\(formatter.string(from: Date())).mp4")

            let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }

            if let ffmpeg {
                try await runFFmpeg(
                    ffmpeg, input: videoURL, output: outputURL,
                    start: trimStart, end: trimEnd)
            } else {
                try await videoToolboxExport(
                    input: videoURL, output: outputURL,
                    start: trimStart, end: trimEnd)
            }

            try? FileManager.default.removeItem(at: videoURL)
            return outputURL
        } catch {
            print("Export failed: \(error)")
            return nil
        }
    }

    // MARK: Private

    private func loopToStart() {
        seekInternal(trimStart)
    }

    private func seekInternal(_ time: Double) {
        player?.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func runFFmpeg(
        _ ffmpeg: String, input: URL, output: URL, start: Double, end: Double
    ) async throws {
        try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: ffmpeg)
                p.arguments = [
                    "-y", "-i", input.path,
                    "-ss", String(format: "%.3f", start),
                    "-to", String(format: "%.3f", end),
                    "-c:v", "libx264", "-preset", "medium", "-crf", "23",
                    "-pix_fmt", "yuv420p", "-an", output.path,
                ]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do {
                    try p.run(); p.waitUntilExit()
                    if p.terminationStatus == 0 { cont.resume() }
                    else {
                        cont.resume(throwing: NSError(
                            domain: "imp-rec", code: Int(p.terminationStatus)))
                    }
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    private func videoToolboxExport(
        input: URL, output: URL, start: Double, end: Double
    ) async throws {
        let asset = AVURLAsset(url: input)
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        guard let videoTrack else {
            throw NSError(domain: "imp-rec", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No video track found"])
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let transformedSize = naturalSize.applying(transform)
        let width = Int(abs(transformedSize.width))
        let height = Int(abs(transformedSize.height))

        let timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600))

        let pixelCount = width * height
        let targetBitRate = Int(Double(pixelCount) * 0.1 * 30)

        let compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: targetBitRate,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
            AVVideoMaxKeyFrameIntervalKey: 60,
            AVVideoQualityKey: 0.5,
        ]

        let writerSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProperties,
        ]

        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]

        let writer = try AVAssetWriter(url: output, fileType: .mp4)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false
        writerInput.transform = transform
        writer.add(writerInput)

        let exportQueue = DispatchQueue(label: "imp-rec.export")

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerSettings)
        reader.add(readerOutput)

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: timeRange.start)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writerInput.requestMediaDataWhenReady(on: exportQueue) {
                while writerInput.isReadyForMoreMediaData {
                    if let sample = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(sample)
                    } else {
                        writerInput.markAsFinished()
                        writer.finishWriting {
                            if writer.status == .completed { cont.resume() }
                            else { cont.resume(throwing: writer.error ?? NSError(domain: "imp-rec", code: -1)) }
                        }
                        return
                    }
                }
            }
        }
    }

    private func avExport(input: URL, output: URL) async throws {
        let asset = AVURLAsset(url: input)
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetHighestQuality)
        else { throw NSError(domain: "imp-rec", code: -1) }
        session.outputURL = output
        session.outputFileType = .mp4
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: trimStart, preferredTimescale: 600),
            end: CMTime(seconds: trimEnd, preferredTimescale: 600))
        await session.export()
        guard session.status == .completed else {
            throw session.error ?? NSError(domain: "imp-rec", code: -1)
        }
    }
}

// MARK: - Editor View

struct EditorView: View {
    @ObservedObject var state: EditorState
    let onDone: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let player = state.player {
                PlayerView(player: player)
                    .background(Color.black)
            } else {
                Color.black.overlay { ProgressView() }
            }

            // Controls
            VStack(spacing: 6) {
                TrimBar(
                    trimStart: $state.trimStart,
                    trimEnd: $state.trimEnd,
                    duration: state.duration,
                    currentTime: state.currentTime,
                    onDragStart: { state.beginDrag() },
                    onSeek: { state.seek(to: $0) },
                    onDragEnd: { state.endDrag() }
                )

                HStack(spacing: 6) {
                    Button(action: { state.togglePlayback() }) {
                        Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.borderless)

                    Text(formatTime(state.currentTime))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Spacer()

                    if state.duration > 0 {
                        Text(
                            "\(formatTime(state.trimStart))–\(formatTime(state.trimEnd))  (\(formatTime(state.trimEnd - state.trimStart)))"
                        )
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Bottom bar
            HStack {
                if let size = fileSize(state.videoURL) {
                    Text(size)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if state.isExporting {
                    ProgressView()
                        .controlSize(.small)
                    Text("Exporting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Save") {
                    Task {
                        if let url = await state.exportVideo() {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                            onDone()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.isExporting || state.duration == 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 480, minHeight: 360)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.space) { state.togglePlayback(); return .handled }
        .onKeyPress(.leftArrow) { state.stepFrame(forward: false); return .handled }
        .onKeyPress(.rightArrow) { state.stepFrame(forward: true); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: ",")) { _ in
            state.stepFrame(forward: false); return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: ".")) { _ in
            state.stepFrame(forward: true); return .handled
        }
        .task {
            await state.setup()
            isFocused = true
        }
    }

    private func fileSize(_ url: URL) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
            let s = a[.size] as? Int64
        else { return nil }
        return ByteCountFormatter.string(fromByteCount: s, countStyle: .file)
    }
}

// MARK: - Player View

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerNSView { PlayerNSView(player: player) }
    func updateNSView(_ v: PlayerNSView, context: Context) { v.updatePlayer(player) }
}

class PlayerNSView: NSView {
    private let playerLayer: AVPlayerLayer

    init(player: AVPlayer) {
        playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func updatePlayer(_ player: AVPlayer) { playerLayer.player = player }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - Trim Bar

struct TrimBar: View {
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    let duration: Double
    let currentTime: Double
    var onDragStart: () -> Void = {}
    let onSeek: (Double) -> Void
    var onDragEnd: () -> Void = {}

    private let trackHeight: CGFloat = 4
    private let handleH: CGFloat = 14

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x0 = xFor(trimStart, in: w)
            let x1 = xFor(trimEnd, in: w)
            let xPlay = xFor(currentTime, in: w)

            Canvas { ctx, size in
                let trackY = (size.height - trackHeight) / 2
                let trackRect = CGRect(x: 0, y: trackY, width: size.width, height: trackHeight)
                ctx.fill(
                    Path(roundedRect: trackRect, cornerRadius: trackHeight / 2),
                    with: .color(Color(white: 0.2)))

                if x0 > 0 {
                    ctx.fill(
                        Path(roundedRect: CGRect(x: 0, y: trackY, width: x0, height: trackHeight),
                             cornerRadius: trackHeight / 2),
                        with: .color(Color(white: 0.08)))
                }
                if x1 < w {
                    ctx.fill(
                        Path(roundedRect: CGRect(x: x1, y: trackY, width: w - x1, height: trackHeight),
                             cornerRadius: trackHeight / 2),
                        with: .color(Color(white: 0.08)))
                }

                let activeRect = CGRect(x: x0, y: trackY, width: max(0, x1 - x0), height: trackHeight)
                ctx.fill(
                    Path(roundedRect: activeRect, cornerRadius: trackHeight / 2),
                    with: .color(Color(white: 0.35)))

                if duration > 0 {
                    let phRect = CGRect(x: xPlay - 3, y: (size.height - 6) / 2, width: 6, height: 6)
                    ctx.fill(Path(ellipseIn: phRect), with: .color(.white))
                }

                let handleY = (size.height - handleH) / 2
                ctx.fill(
                    Path(roundedRect: CGRect(x: x0 - 1.5, y: handleY, width: 3, height: handleH),
                         cornerRadius: 1.5),
                    with: .color(.yellow))
                ctx.fill(
                    Path(roundedRect: CGRect(x: x1 - 1.5, y: handleY, width: 3, height: handleH),
                         cornerRadius: 1.5),
                    with: .color(.yellow))
            }
            .overlay {
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: 22)
                        .contentShape(Rectangle())
                        .offset(x: x0 - 11)
                        .gesture(drag(side: .start, width: w))
                    Spacer(minLength: 0)
                }
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Color.clear
                        .frame(width: 22)
                        .contentShape(Rectangle())
                        .offset(x: -(w - x1 - 11))
                        .gesture(drag(side: .end, width: w))
                }
            }
            .coordinateSpace(name: "trimBar")
        }
        .frame(height: 20)
    }

    private func xFor(_ time: Double, in width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(time / duration) * width
    }

    private enum Side { case start, end }

    private func drag(side: Side, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("trimBar"))
            .onChanged { value in
                if !isDragging { isDragging = true; onDragStart() }
                guard duration > 0 else { return }
                let t = max(0, min(duration, Double(value.location.x / width) * duration))
                switch side {
                case .start:
                    trimStart = max(0, min(t, trimEnd - 0.1))
                    onSeek(trimStart)
                case .end:
                    trimEnd = min(duration, max(t, trimStart + 0.1))
                    onSeek(trimEnd)
                }
            }
            .onEnded { _ in
                isDragging = false
                onDragEnd()
            }
    }
}

// MARK: - Helpers

private func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite && seconds >= 0 else { return "0:00" }
    let m = Int(seconds) / 60
    let s = Int(seconds) % 60
    return String(format: "%d:%02d", m, s)
}
