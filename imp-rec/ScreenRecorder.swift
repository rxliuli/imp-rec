import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

@MainActor
class ScreenRecorder: ObservableObject {
    @Published private(set) var isRecording = false

    private var stream: SCStream?
    private var streamOutput: RecordingStreamOutput?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private(set) var outputURL: URL?

    func startRecording(with filter: SCContentFilter) async {
        guard !isRecording else { return }

        do {
            var width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
            var height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))

            if width <= 0 || height <= 0 {
                let scale = Int(NSScreen.main?.backingScaleFactor ?? 2)
                let screen = NSScreen.main ?? NSScreen.screens[0]
                width = Int(screen.frame.width) * scale
                height = Int(screen.frame.height) * scale
            }

            // H.264 requires even dimensions
            width = max(2, width & ~1)
            height = max(2, height & ~1)

            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.showsCursor = true
            config.capturesAudio = false

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let fileName = "imp-rec-\(formatter.string(from: Date())).mov"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            outputURL = url

            let writer = try AVAssetWriter(url: url, fileType: .mov)
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]

            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            writer.startWriting()

            assetWriter = writer
            videoInput = input

            let output = RecordingStreamOutput(assetWriter: writer, videoInput: input)
            streamOutput = output

            let scStream = SCStream(filter: filter, configuration: config, delegate: nil)
            try scStream.addStreamOutput(
                output, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
            try await scStream.startCapture()

            stream = scStream
            isRecording = true
        } catch {
            print("Failed to start recording: \(error)")
            cleanup()
        }
    }

    func stopRecording() async -> URL? {
        guard isRecording else { return nil }

        do {
            try await stream?.stopCapture()
        } catch {
            print("Failed to stop capture: \(error)")
        }

        stream = nil
        streamOutput = nil

        if assetWriter?.status == .writing {
            videoInput?.markAsFinished()
            await assetWriter?.finishWriting()
        }

        let url = outputURL
        cleanup()
        return url
    }

    private func cleanup() {
        stream = nil
        streamOutput = nil
        assetWriter = nil
        videoInput = nil
        outputURL = nil
        isRecording = false
    }
}

class RecordingStreamOutput: NSObject, SCStreamOutput {
    private let assetWriter: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private var sessionStarted = false

    init(assetWriter: AVAssetWriter, videoInput: AVAssetWriterInput) {
        self.assetWriter = assetWriter
        self.videoInput = videoInput
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
            sampleBuffer.isValid,
            CMSampleBufferDataIsReady(sampleBuffer)
        else { return }

        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let statusRaw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRaw),
            status == .complete
        else {
            return
        }

        guard assetWriter.status == .writing else { return }

        if !sessionStarted {
            assetWriter.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            sessionStarted = true
        }

        if videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
        }
    }
}
