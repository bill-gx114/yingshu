import AVFoundation
import CryptoKit
import Foundation

// Offline measurement of the 0.7 prepare path. No player or audio output exists.
// Network capture is deliberately separate; callers supply an already bounded prefix.
enum MeasurementError: Error { case invalidInput, tooShort, invalidOutput }
func decode(_ prefix: URL, into output: URL) throws -> Double {
    let input = try AVAudioFile(forReading: prefix, commonFormat: .pcmFormatFloat32, interleaved: false)
    let format = input.processingFormat
    guard format.sampleRate.isFinite, (8_000...96_000).contains(format.sampleRate), (1...2).contains(format.channelCount) else { throw MeasurementError.invalidInput }
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
        AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
    let writer = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
    let target = AVAudioFramePosition(format.sampleRate * 20)
    var written: AVAudioFramePosition = 0
    while written < target {
        do { try input.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, target - written))) }
        catch { if Double(written)/format.sampleRate >= 1 { break }; throw error }
        if buffer.frameLength == 0 { break }
        try writer.write(from: buffer); written += AVAudioFramePosition(buffer.frameLength)
    }
    guard Double(written)/format.sampleRate >= 1 else { throw MeasurementError.tooShort }
    return Double(written)/format.sampleRate
}
func validate(_ output: URL) async throws -> Double {
    let asset = AVURLAsset(url: output)
    let playable = try await asset.load(.isPlayable), duration = try await asset.load(.duration).seconds
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    guard playable, !tracks.isEmpty, duration.isFinite, duration >= 1, duration <= 20.001 else { throw MeasurementError.invalidOutput }
    let file = try AVAudioFile(forReading: output)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024)!
    try file.read(into: buffer); guard buffer.frameLength > 0 else { throw MeasurementError.invalidOutput }
    return duration
}
@main enum PreviewPrefixMeasurement {
    static func main() async throws {
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let inputData = try Data(contentsOf: input)
        var measurements: [[String: Any]] = []
        for run in 0..<2 {
            let output = input.deletingLastPathComponent().appendingPathComponent(input.deletingPathExtension().lastPathComponent + "-run\(run).wav")
            let start = ProcessInfo.processInfo.systemUptime
            let decodedDuration = try decode(input, into: output)
            let decoded = ProcessInfo.processInfo.systemUptime
            let validatedDuration = try await validate(output)
            let end = ProcessInfo.processInfo.systemUptime
            measurements.append(["run":run,"decode_wav_ms":(decoded-start)*1000,"validate_wav_ms":(end-decoded)*1000,
                "local_total_ms":(end-start)*1000,"decoded_duration":decodedDuration,"validated_duration":validatedDuration,
                "wav_bytes":try output.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0])
        }
        let report: [String: Any] = ["input":input.lastPathComponent,"input_bytes":inputData.count,
            "input_sha256":SHA256.hash(data:inputData).map{String(format:"%02x",$0)}.joined(),
            "process_first_then_warm":measurements,"no_playback":true]
        let data = try JSONSerialization.data(withJSONObject:report, options:[.prettyPrinted,.sortedKeys])
        print(String(decoding:data,as:UTF8.self))
    }
}
