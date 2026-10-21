import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum VideoPreset: String, CaseIterable, Identifiable {
    case p480, p720, p1080, hevc1080, hevc4k
    var id: String { rawValue }

    var label: String {
        switch self {
        case .p480: "480p"
        case .p720: "720p"
        case .p1080: "1080p"
        case .hevc1080: "1080p HEVC"
        case .hevc4k: "4K HEVC"
        }
    }

    var detail: String {
        switch self {
        case .p480: "H.264, smallest, plays everywhere"
        case .p720: "H.264, good for messengers"
        case .p1080: "H.264, full HD"
        case .hevc1080: "HEVC, full HD at about half the size"
        case .hevc4k: "HEVC, keeps 4K resolution"
        }
    }

    var avPreset: String {
        switch self {
        case .p480: AVAssetExportPreset640x480
        case .p720: AVAssetExportPreset1280x720
        case .p1080: AVAssetExportPreset1920x1080
        case .hevc1080: AVAssetExportPresetHEVC1920x1080
        case .hevc4k: AVAssetExportPresetHEVC3840x2160
        }
    }
}

enum VideoContainer: String, CaseIterable, Identifiable {
    case mp4, mov
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var fileType: AVFileType { self == .mp4 ? .mp4 : .mov }
}

enum AudioFormat: String, CaseIterable, Identifiable {
    case m4a, wav, aiff, caf
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

enum MediaEngine {
    static func compressVideo(_ url: URL, preset: VideoPreset, outputDir: URL?, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let output = OutputNamer.file(for: url, suffix: "-compressed", ext: "mp4", in: outputDir)
        try await export(AVURLAsset(url: url), preset: preset.avPreset, fileType: .mp4, to: output, progress: progress)
        return output
    }

    static func convertVideo(_ url: URL, to container: VideoContainer, outputDir: URL?, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let sameExt = url.pathExtension.lowercased() == container.rawValue
        let output = OutputNamer.file(for: url, suffix: sameExt ? "-converted" : "", ext: container.rawValue, in: outputDir)
        let asset = AVURLAsset(url: url)
        // Passthrough keeps quality and is instant; re-encode only if the container can't hold the source codecs.
        do {
            try await export(asset, preset: AVAssetExportPresetPassthrough, fileType: container.fileType, to: output, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: output)
            try await export(asset, preset: AVAssetExportPresetHighestQuality, fileType: container.fileType, to: output, progress: progress)
        }
        return output
    }

    static func extractAudio(_ url: URL, outputDir: URL?, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw HaluError.failed("This video has no audio track.")
        }
        let output = OutputNamer.file(for: url, suffix: "", ext: "m4a", in: outputDir)
        try await export(asset, preset: AVAssetExportPresetAppleM4A, fileType: .m4a, to: output, progress: progress)
        return output
    }

    static func makeGIF(_ url: URL, fps: Double, width: Double, outputDir: URL?, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw HaluError.unreadable(url) }
        let frameCount = min(max(Int(duration * fps), 1), 900)
        let output = OutputNamer.file(for: url, suffix: "", ext: "gif", in: outputDir)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: width, height: width * 4)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw HaluError.writeFailed(output)
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary

        for i in 0..<frameCount {
            let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            let (image, _) = try await generator.image(at: time)
            CGImageDestinationAddImage(dest, image, frameProps)
            progress(Double(i + 1) / Double(frameCount))
        }
        guard CGImageDestinationFinalize(dest) else { throw HaluError.writeFailed(output) }
        return output
    }

    static func convertAudio(_ url: URL, to format: AudioFormat, outputDir: URL?, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let sameExt = url.pathExtension.lowercased() == format.rawValue
        let output = OutputNamer.file(for: url, suffix: sameExt ? "-converted" : "", ext: format.rawValue, in: outputDir)
        if format == .m4a {
            try await export(AVURLAsset(url: url), preset: AVAssetExportPresetAppleM4A, fileType: .m4a, to: output, progress: progress)
            return output
        }

        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: url) } catch { throw HaluError.unreadable(url) }
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: output.pathExtension == "aiff",
            AVLinearPCMIsNonInterleaved: false,
        ]
        let out = try AVAudioFile(forWriting: output, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else { throw HaluError.writeFailed(output) }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try out.write(from: buffer)
            progress(Double(input.framePosition) / Double(max(input.length, 1)))
        }
        return output
    }

    private static func export(_ asset: AVAsset, preset: String, fileType: AVFileType, to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw HaluError.failed("This file can't be processed with the selected preset.")
        }
        guard session.supportedFileTypes.contains(fileType) else {
            throw HaluError.failed("Can't save this file as .\(output.pathExtension).")
        }
        session.outputURL = output
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true

        let poller = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { poller.cancel() }

        await session.export()
        guard session.status == .completed else {
            throw session.error ?? HaluError.failed("Export failed.")
        }
        progress(1)
    }
}
