import Foundation
import FoundationModels

public enum WritingAssistantError: LocalizedError, Sendable, Equatable {
    case unavailable(String)
    case emptyText
    case unsupportedLanguage(String?)
    case missingTargetLanguage
    case unsupportedTargetLanguage(String)
    case textTooLong
    case blockedBySafety
    case refused
    case busy
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            reason
        case .emptyText:
            "Select some text first."
        case .unsupportedLanguage(let language?):
            "Apple Intelligence can't work with \(language) text yet."
        case .unsupportedLanguage(nil):
            "Apple Intelligence doesn't support the language of this text yet."
        case .missingTargetLanguage:
            "Choose a language to translate into."
        case .unsupportedTargetLanguage(let language):
            "Apple Intelligence can't translate into \(language) yet."
        case .textTooLong:
            "The selected text is too long. Select a shorter passage and try again."
        case .blockedBySafety:
            "Apple Intelligence declined this text because of its safety guidelines."
        case .refused:
            "Apple Intelligence declined to rewrite this text."
        case .busy:
            "Apple Intelligence is busy. Try again in a moment."
        case .failed(let message):
            message
        }
    }

    static func from(_ error: any Error) -> any Error {
        if error is WritingAssistantError || error is CancellationError { return error }
        if #available(macOS 27, *), let mapped = fromCurrent(error) { return mapped }
        if let generation = error as? LanguageModelSession.GenerationError { return from(generation) }
        return WritingAssistantError.failed(error.localizedDescription)
    }

    @available(macOS 27, *)
    private static func fromCurrent(_ error: any Error) -> WritingAssistantError? {
        if let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded: return .textTooLong
            case .guardrailViolation: return .blockedBySafety
            case .refusal: return .refused
            case .unsupportedLanguageOrLocale: return .unsupportedLanguage(nil)
            case .rateLimited, .timeout: return .busy
            default: return .failed(error.localizedDescription)
            }
        }
        if error is LanguageModelSession.Error { return .busy }
        if error is SystemLanguageModel.Error {
            return .unavailable("Apple Intelligence model files are not available yet. Try again later.")
        }
        return nil
    }

    private static func from(_ error: LanguageModelSession.GenerationError) -> WritingAssistantError {
        switch error {
        case .exceededContextWindowSize: .textTooLong
        case .guardrailViolation: .blockedBySafety
        case .refusal: .refused
        case .unsupportedLanguageOrLocale: .unsupportedLanguage(nil)
        case .rateLimited, .concurrentRequests: .busy
        case .assetsUnavailable: .unavailable("Apple Intelligence model files are not available yet. Try again later.")
        default: .failed(error.localizedDescription)
        }
    }
}
