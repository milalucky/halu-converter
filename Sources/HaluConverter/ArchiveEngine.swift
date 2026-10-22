import Foundation

enum ArchiveFormat: String, CaseIterable, Identifiable {
    case zip, tarGz
    var id: String { rawValue }
    var label: String { self == .zip ? "ZIP" : "TAR.GZ" }
    var fileExtension: String { self == .zip ? "zip" : "tar.gz" }
}

enum SubtitleFormat: String, CaseIterable, Identifiable {
    case srt, vtt, txt
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

enum ArchiveEngine {
    /// Packs files and folders (all from the same folder as the first one) into one archive.
    static func make(_ urls: [URL], format: ArchiveFormat, outputDir: URL?) async throws -> URL {
        let parent = urls[0].deletingLastPathComponent()
        let base = urls.count == 1 ? urls[0].deletingPathExtension() : parent.appendingPathComponent("Archive")
        let output = OutputNamer.file(for: base.appendingPathExtension("x"), suffix: "", ext: format.fileExtension, in: outputDir ?? parent)
        let names = urls.map { $0.path.hasPrefix(parent.path + "/") ? String($0.path.dropFirst(parent.path.count + 1)) : $0.path }
        switch format {
        case .zip:
            // -X drops extended attributes, -y keeps symlinks; .DS_Store files are left out.
            try await Shell.run("/usr/bin/zip", ["-r", "-q", "-X", "-y", output.path] + names + ["-x", "*.DS_Store"], in: parent)
        case .tarGz:
            try await Shell.run("/usr/bin/tar", ["--no-mac-metadata", "--exclude", ".DS_Store", "-czf", output.path] + names, in: parent)
        }
        return output
    }

    /// Extracts ZIP, RAR, 7Z, TAR, GZ, BZ2, XZ into a new folder next to the archive.
    static func extract(_ url: URL, outputDir: URL?) async throws -> [URL] {
        let name = url.lastPathComponent
            .replacingOccurrences(of: #"\.(tar\.gz|tar\.bz2|tar\.xz|tgz|zip|rar|7z|tar|gz|bz2|xz)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        let folder = try OutputNamer.folder(for: url.deletingLastPathComponent().appendingPathComponent(name + ".x"), suffix: "", in: outputDir)
        let ext = url.pathExtension.lowercased()
        do {
            if ext == "zip" {
                try await Shell.run("/usr/bin/ditto", ["-x", "-k", url.path, folder.path])
            } else if ["gz", "bz2", "xz"].contains(ext) && !url.lastPathComponent.lowercased().contains(".tar.") {
                // A single compressed file (e.g. log.gz), not a tarball.
                let out = folder.appendingPathComponent(name)
                let tool = ["gz": "/usr/bin/gunzip", "bz2": "/usr/bin/bunzip2", "xz": "/usr/bin/xz"][ext]!
                try await Shell.run("/bin/sh", ["-c", "\"$0\" -dc \"$1\" > \"$2\"", tool, url.path, out.path])
            } else {
                try await Shell.run("/usr/bin/tar", ["-xf", url.path, "-C", folder.path])
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw HaluError.failed("Couldn't extract “\(url.lastPathComponent)”. It may be damaged or password-protected.")
        }
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return [folder] + items
    }
}

enum SubtitleEngine {
    struct Cue { var start: Double; var end: Double; var text: String }

    static func convert(_ url: URL, to format: SubtitleFormat, outputDir: URL?) throws -> URL {
        guard let text = try? String(contentsOf: url, encoding: .utf8) ?? String(contentsOf: url, encoding: .isoLatin1) else {
            throw HaluError.unreadable(url)
        }
        let cues = parse(text)
        guard !cues.isEmpty else { throw HaluError.failed("No subtitles found in “\(url.lastPathComponent)”.") }
        let sameExt = url.pathExtension.lowercased() == format.rawValue
        let output = OutputNamer.file(for: url, suffix: sameExt ? "-converted" : "", ext: format.rawValue, in: outputDir)
        let body: String
        switch format {
        case .srt:
            body = cues.enumerated().map { i, cue in "\(i + 1)\n\(stamp(cue.start, comma: true)) --> \(stamp(cue.end, comma: true))\n\(cue.text)\n" }
                .joined(separator: "\n")
        case .vtt:
            body = "WEBVTT\n\n" + cues.map { "\(stamp($0.start, comma: false)) --> \(stamp($0.end, comma: false))\n\($0.text)\n" }
                .joined(separator: "\n")
        case .txt:
            body = cues.map(\.text).joined(separator: "\n") + "\n"
        }
        do { try body.write(to: output, atomically: true, encoding: .utf8) } catch { throw HaluError.writeFailed(output) }
        return output
    }

    /// Reads both SRT and WebVTT: any block with a "-->" timing line is a cue.
    static func parse(_ text: String) -> [Cue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2, let start = seconds(parts[0]),
                  let end = seconds(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "")
            else { return nil }
            let body = lines[(timingIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : Cue(start: start, end: end, text: body)
        }
    }

    private static func seconds(_ stamp: String) -> Double? {
        let parts = stamp.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        let values = parts.compactMap { Double($0) }
        guard values.count == parts.count else { return nil }
        return values.reduce(0) { $0 * 60 + $1 }
    }

    private static func stamp(_ seconds: Double, comma: Bool) -> String {
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, comma ? "," : ".", ms % 1000)
    }
}

enum Shell {
    /// Runs a tool without blocking, throwing its stderr on failure.
    static func run(_ executable: String, _ arguments: [String], in directory: URL? = nil) async throws {
        _ = try await output(executable, arguments, in: directory)
    }

    /// Like `run`, returning the tool's trimmed stdout.
    static func output(_ executable: String, _ arguments: [String], in directory: URL? = nil) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        let errors = Pipe()
        let output = Pipe()
        process.standardError = errors
        process.standardOutput = output

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            process.terminationHandler = { process in
                let data = errors.fileHandleForReading.readDataToEndOfFile()
                let stdout = output.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: HaluError.failed(message.isEmpty ? "\(executable) failed (\(process.terminationStatus))." : message))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}
