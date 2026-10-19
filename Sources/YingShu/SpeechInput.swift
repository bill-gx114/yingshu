import Combine
import Foundation

/// Keeps the playback/recording contract testable without accessing a microphone.
@MainActor
protocol SpeechInput: AnyObject {
    var changes: AnyPublisher<Void, Never> { get }
    var isRecording: Bool { get }
    var transcript: String { get }
    var originalTranscript: String? { get }
    var cleanupApplied: Bool { get }
    var cleanupIssue: String? { get }
    var status: String { get }
    var audioLevel: Float { get }
    var authorizationGranted: Bool { get }
    var segments: [SpeechSegment] { get }
    var wordSegments: [SpeechSegment] { get }
    var hasFinalTiming: Bool { get }
    var hasFinalResult: Bool { get }
    var enhancedModelAvailability: EnhancedSpeechModelAvailability { get }
    var enhancedModelDownloadProgress: Double? { get }
    var lastIssue: String? { get }
    var isRecognizingFile: Bool { get }
    var onUnexpectedStop: ((String) -> Void)? { get set }
    func configure(options: SpeechRecognitionOptions)
    func refreshEnhancedModelAvailability() async
    func prepareEnhancedModel() async throws
    func cancelEnhancedModelPreparation()
    func start() async throws
    func stop() async -> String
    func cancel()
    func transcribeFile(url: URL, requireOnDevice: Bool?) async throws -> String
}

extension SpeechInput {
    var originalTranscript: String? { nil }
    var cleanupApplied: Bool { false }
    var cleanupIssue: String? { nil }
    var hasFinalResult: Bool { hasFinalTiming }
    var enhancedModelAvailability: EnhancedSpeechModelAvailability { .unavailable("此语音后端不提供增强模型。") }
    var enhancedModelDownloadProgress: Double? { nil }
    func configure(options: SpeechRecognitionOptions) {}
    func refreshEnhancedModelAvailability() async {}
    func prepareEnhancedModel() async throws { throw SpeechRecognitionFailure.message(enhancedModelAvailability.message) }
    func cancelEnhancedModelPreparation() {}

    func transcribeFile(url: URL) async throws -> String {
        try await transcribeFile(url: url, requireOnDevice: nil)
    }
}

extension SpeechCapture: SpeechInput {
    var changes: AnyPublisher<Void, Never> { objectWillChange.map { _ in () }.eraseToAnyPublisher() }
}
