import Foundation
import os
import TunerCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Optional extra for "Understand natural searches": Apple's on-device language model reads English searches the
/// rules couldn't fully place ("something light for a rainy night") into the same filters, when the user presses
/// Return. Only on macOS/iOS 26+ with Apple Intelligence on; the framework is weak-linked (Package.swift,
/// iOS/project.yml) so the Mac app still launches on macOS 15. Every failure, timeout or unavailable model just
/// means "no suggestion": the rule-based results are already on screen. `QueryUnderstanding.refine` validates the
/// answer.
enum NaturalSearchModel {
    private static let log = Logger(subsystem: "app.tuner.macos", category: "NaturalSearch")

    /// The model is on this device, ready, and speaks English.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            let model = SystemLanguageModel.default
            return model.availability == .available && model.supportsLocale(Locale(identifier: "en_US"))
        }
        #endif
        return false
    }

    /// Loads the model ahead of a likely request (the search field got focus), so the first answer is quicker.
    static func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *), isAvailable {
            LanguageModelSession(instructions: instructions).prewarm()
        }
        #endif
    }

    /// The model's reading of `query`, or nil when it's unavailable, fails, or takes longer than `timeout`.
    static func suggestion(for query: String, timeout: Duration = .seconds(6)) async -> ModelSearchSuggestion? {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *), isAvailable {
            let started = ContinuousClock.now
            let result = await firstOf(timeout: timeout) { await ask(query) }
            log.info("Model search suggestion: \(result == nil ? "none" : "ok", privacy: .public) in \((ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
            return result
        }
        #endif
        return nil
    }

    /// Runs `work`, but returns nil after `timeout` without waiting for it (the model call may not stop promptly
    /// when cancelled).
    private static func firstOf<T: Sendable>(timeout: Duration, _ work: @escaping @Sendable () async -> T?) async -> T? {
        let done = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { continuation in
            let task = Task {
                let value = await work()
                if done.withLock({ let first = !$0; $0 = true; return first }) { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if done.withLock({ let first = !$0; $0 = true; return first }) {
                    task.cancel()
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static let instructions = """
        You turn a search typed into a TV and movie app into filters. Fill a field only when the search clearly \
        asks for it; otherwise use "any", an empty list, false or an empty string. Moods map to genres (for example \
        "something light" is comedy, "scary" is horror, "edge of my seat" is thriller). titleWords are only words \
        from the search that name a specific title, person or topic to look for in titles.
        """

    #if canImport(FoundationModels)
    @available(macOS 26, iOS 26, *)
    private static func ask(_ query: String) async -> ModelSearchSuggestion? {
        do {
            let root = DynamicGenerationSchema(name: "SearchFilters", properties: [
                .init(name: "kind", description: "movie or series only if the search asks for one",
                      schema: DynamicGenerationSchema(name: "Kind", anyOf: ["any", "movie", "series"])),
                .init(name: "genres", description: "at most two genres the search asks for, by name or by mood",
                      schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(name: "Genre", anyOf: SearchGenre.allCases.map(\.rawValue)),
                                                      minimumElements: 0, maximumElements: 2)),
                .init(name: "language", description: "the language or country of origin the search asks for",
                      schema: DynamicGenerationSchema(name: "Language", anyOf: ["any"] + SearchLanguage.allCases.map(\.rawValue))),
                .init(name: "topRated", description: "true only if the search asks for good, acclaimed or classic titles",
                      schema: DynamicGenerationSchema(type: Bool.self)),
                .init(name: "titleWords", description: "words from the search naming a title, person or topic; empty if none",
                      schema: DynamicGenerationSchema(type: String.self)),
            ])
            let schema = try GenerationSchema(root: root, dependencies: [])
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: query, schema: schema, includeSchemaInPrompt: true,
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 120)
            )
            let content = response.content
            let kind = try content.value(String.self, forProperty: "kind")
            let language = try content.value(String.self, forProperty: "language")
            return ModelSearchSuggestion(
                kind: kind == "any" ? nil : kind,
                genres: try content.value([String].self, forProperty: "genres"),
                languages: language == "any" ? [] : [language],
                topRated: try content.value(Bool.self, forProperty: "topRated"),
                titleWords: try content.value(String.self, forProperty: "titleWords")
            )
        } catch {
            // Unsupported language, guardrails, context size, cancellation: no suggestion. The query isn't logged.
            log.info("Model search suggestion failed: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
    }
    #endif
}
