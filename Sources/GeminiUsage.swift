import Foundation

struct GeminiModalityTokenCount: Codable, Sendable {
    let modality: String
    let tokenCount: Int
}

struct GeminiUsageMetadata: Decodable, Sendable {
    let promptTokenCount: Int?
    let responseTokenCount: Int?
    let candidatesTokenCount: Int?
    let thoughtsTokenCount: Int?
    let totalTokenCount: Int?
    let promptTokensDetails: [GeminiModalityTokenCount]?
    let responseTokensDetails: [GeminiModalityTokenCount]?
    let candidatesTokensDetails: [GeminiModalityTokenCount]?

    var outputTokenCount: Int {
        responseTokenCount ?? candidatesTokenCount ?? 0
    }

    var outputTokensDetails: [GeminiModalityTokenCount] {
        responseTokensDetails ?? candidatesTokensDetails ?? []
    }

    static func decode(_ dictionary: [String: Any]) -> GeminiUsageMetadata? {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary) else { return nil }
        return try? JSONDecoder().decode(GeminiUsageMetadata.self, from: data)
    }
}

struct GeminiUsageSummary: Sendable {
    let imageAnalyses: Int
    let liveTurns: Int
    let textTutorTurns: Int
    let inputAudioSeconds: Double
    let outputAudioSeconds: Double
    let imageCostUSD: Double
    let liveCostUSD: Double
    let textTutorCostUSD: Double

    var totalCostUSD: Double { imageCostUSD + liveCostUSD + textTutorCostUSD }
}

private struct GeminiUsageEvent: Codable, Sendable {
    let timestamp: Date
    let category: String
    let model: String
    let promptTokens: Int
    let responseTokens: Int
    let thoughtsTokens: Int
    let inputTextTokens: Int
    let inputAudioTokens: Int
    let inputImageTokens: Int
    let inputVideoTokens: Int
    let outputTextTokens: Int
    let outputAudioTokens: Int
    let inputAudioSeconds: Double
    let outputAudioSeconds: Double
    let estimatedCostUSD: Double
    let pricingSnapshot: String
}

actor GeminiUsageLedger {
    static let shared = GeminiUsageLedger()

    private let directory = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    )[0].appendingPathComponent("Anki-Lernassistent", isDirectory: true)

    private var jsonlURL: URL {
        directory.appendingPathComponent("gemini-usage.jsonl")
    }

    private var csvURL: URL {
        directory.appendingPathComponent("gemini-kosten.csv")
    }

    func recordImageAnalysis(
        model: String,
        usage: GeminiUsageMetadata,
        freeTier: Bool = false
    ) {
        let prompt = usage.promptTokenCount ?? 0
        let response = usage.outputTokenCount
        let thoughts = usage.thoughtsTokenCount ?? 0
        let input = modalityCounts(usage.promptTokensDetails ?? [], total: prompt)
        let output = modalityCounts(usage.outputTokensDetails, total: response)
        let paidCost = Double(prompt) * 0.75 / 1_000_000
            + Double(response + thoughts) * 3.75 / 1_000_000
        let cost = freeTier ? 0 : paidCost

        append(GeminiUsageEvent(
            timestamp: Date(),
            category: "Bildanalyse",
            model: freeTier ? model + " (Free Tier gewählt)" : model,
            promptTokens: prompt,
            responseTokens: response,
            thoughtsTokens: thoughts,
            inputTextTokens: input.text,
            inputAudioTokens: input.audio,
            inputImageTokens: input.image,
            inputVideoTokens: input.video,
            outputTextTokens: output.text,
            outputAudioTokens: output.audio,
            inputAudioSeconds: 0,
            outputAudioSeconds: 0,
            estimatedCostUSD: cost,
            pricingSnapshot: freeTier
                ? "Gemini Free Tier gewählt: geschätzt $0; tatsächliche Abrechnung hängt vom Google-Projekt des Schlüssels ab (Stand 2026-09-11)"
                : "Gemini 3.8 Flash Standard: Input $0.75/M, Output inkl. Denken $3.75/M (Stand 2026-09-11)"
        ))
    }

    func recordLiveTurn(
        model: String,
        usage: GeminiUsageMetadata,
        inputAudioSeconds: Double,
        outputAudioSeconds: Double,
        freeTier: Bool = false
    ) {
        let prompt = usage.promptTokenCount ?? 0
        let response = usage.outputTokenCount
        let thoughts = usage.thoughtsTokenCount ?? 0
        let input = modalityCounts(usage.promptTokensDetails ?? [], total: prompt)
        let output = modalityCounts(usage.outputTokensDetails, total: response)
        let paidCost = Double(input.text) * 0.75 / 1_000_000
            + Double(input.audio) * 3.00 / 1_000_000
            + Double(input.image + input.video) * 1.00 / 1_000_000
            + Double(output.text + thoughts) * 4.50 / 1_000_000
            + Double(output.audio) * 12.00 / 1_000_000
        let cost = freeTier ? 0 : paidCost

        append(GeminiUsageEvent(
            timestamp: Date(),
            category: "Live-Sprache",
            model: freeTier ? model + " (Free Tier gewählt)" : model,
            promptTokens: prompt,
            responseTokens: response,
            thoughtsTokens: thoughts,
            inputTextTokens: input.text,
            inputAudioTokens: input.audio,
            inputImageTokens: input.image,
            inputVideoTokens: input.video,
            outputTextTokens: output.text,
            outputAudioTokens: output.audio,
            inputAudioSeconds: inputAudioSeconds,
            outputAudioSeconds: outputAudioSeconds,
            estimatedCostUSD: cost,
            pricingSnapshot: freeTier
                ? "Gemini 3.1 Flash Live Preview Free Tier gewählt: geschätzt $0; tatsächliche Abrechnung hängt vom Google-Projekt des Schlüssels ab (Stand 2026-09-11)"
                : "Gemini 3.1 Flash Live Preview: In Text $0.75/M, Audio $3/M, Bild/Video $1/M; Out Text/Denken $4.50/M, Audio $12/M (Stand 2026-09-11)"
        ))
    }

    func recordTextTutor(mode: TextTutorMode, usage: GeminiUsageMetadata) {
        let prompt = usage.promptTokenCount ?? 0
        let response = usage.outputTokenCount
        let thoughts = usage.thoughtsTokenCount ?? 0
        let input = modalityCounts(usage.promptTokensDetails ?? [], total: prompt)
        let output = modalityCounts(usage.outputTokensDetails, total: response)
        let cost = Double(prompt) * mode.inputPricePerMillion / 1_000_000
            + Double(response + thoughts) * mode.outputPricePerMillion / 1_000_000

        append(GeminiUsageEvent(
            timestamp: Date(),
            category: "Text-Tutor",
            model: mode.modelID,
            promptTokens: prompt,
            responseTokens: response,
            thoughtsTokens: thoughts,
            inputTextTokens: input.text,
            inputAudioTokens: input.audio,
            inputImageTokens: input.image,
            inputVideoTokens: input.video,
            outputTextTokens: output.text,
            outputAudioTokens: output.audio,
            inputAudioSeconds: 0,
            outputAudioSeconds: 0,
            estimatedCostUSD: cost,
            pricingSnapshot: "\(mode.label) Standard: \(mode.priceDescription), Output inklusive Denken (Stand 2026-09-11)"
        ))
    }

    func recordTextTutorTokens(mode: TextTutorMode, promptTokens: Int, responseTokens: Int) {
        guard promptTokens > 0 || responseTokens > 0 else { return }
        let cost = Double(promptTokens) * mode.inputPricePerMillion / 1_000_000
            + Double(responseTokens) * mode.outputPricePerMillion / 1_000_000
        append(GeminiUsageEvent(
            timestamp: Date(),
            category: "Text-Tutor",
            model: mode.modelID + " (Text-API Live)",
            promptTokens: promptTokens,
            responseTokens: responseTokens,
            thoughtsTokens: 0,
            inputTextTokens: promptTokens,
            inputAudioTokens: 0,
            inputImageTokens: 0,
            inputVideoTokens: 0,
            outputTextTokens: responseTokens,
            outputAudioTokens: 0,
            inputAudioSeconds: 0,
            outputAudioSeconds: 0,
            estimatedCostUSD: cost,
            pricingSnapshot: "\(mode.label) Standard über Text-API Live: \(mode.priceDescription), Output inklusive Denken (Stand 2026-09-11)"
        ))
    }

    func summary() -> GeminiUsageSummary {
        let events = readEvents()
        let images = events.filter { $0.category == "Bildanalyse" }
        let live = events.filter { $0.category == "Live-Sprache" }
        let textTutor = events.filter { $0.category == "Text-Tutor" }
        return GeminiUsageSummary(
            imageAnalyses: images.count,
            liveTurns: live.count,
            textTutorTurns: textTutor.count,
            inputAudioSeconds: live.reduce(0) { $0 + $1.inputAudioSeconds },
            outputAudioSeconds: live.reduce(0) { $0 + $1.outputAudioSeconds },
            imageCostUSD: images.reduce(0) { $0 + $1.estimatedCostUSD },
            liveCostUSD: live.reduce(0) { $0 + $1.estimatedCostUSD },
            textTutorCostUSD: textTutor.reduce(0) { $0 + $1.estimatedCostUSD }
        )
    }

    func exportCSV() throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let formatter = ISO8601DateFormatter()
        let header = [
            "Zeitpunkt", "Kategorie", "Modell", "Input-Token", "Output-Token",
            "Thinking-Token", "Input Text", "Input Audio", "Input Bild", "Input Video",
            "Output Text", "Output Audio", "Mikrofon Sekunden", "Gemini-Audio Sekunden",
            "Geschätzte Kosten USD", "Preisgrundlage"
        ].joined(separator: ",")
        let rows = readEvents().map { event in
            [
                formatter.string(from: event.timestamp), event.category, event.model,
                String(event.promptTokens), String(event.responseTokens), String(event.thoughtsTokens),
                String(event.inputTextTokens), String(event.inputAudioTokens),
                String(event.inputImageTokens), String(event.inputVideoTokens),
                String(event.outputTextTokens), String(event.outputAudioTokens),
                decimal(event.inputAudioSeconds), decimal(event.outputAudioSeconds),
                decimal(event.estimatedCostUSD), event.pricingSnapshot
            ].map(csvEscape).joined(separator: ",")
        }
        try ([header] + rows).joined(separator: "\n").appending("\n")
            .write(to: csvURL, atomically: true, encoding: .utf8)
        return csvURL
    }

    private func modalityCounts(
        _ details: [GeminiModalityTokenCount],
        total: Int
    ) -> (text: Int, audio: Int, image: Int, video: Int) {
        var text = 0
        var audio = 0
        var image = 0
        var video = 0
        for detail in details {
            switch detail.modality.uppercased() {
            case "AUDIO": audio += detail.tokenCount
            case "IMAGE": image += detail.tokenCount
            case "VIDEO": video += detail.tokenCount
            default: text += detail.tokenCount
            }
        }
        let unresolved = max(0, total - text - audio - image - video)
        text += unresolved
        return (text, audio, image, video)
    }

    private func append(_ event: GeminiUsageEvent) {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(event)
            data.append(0x0A)
            if !FileManager.default.fileExists(atPath: jsonlURL.path) {
                FileManager.default.createFile(atPath: jsonlURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: jsonlURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Usage logging must never interrupt the learning session.
        }
    }

    private func readEvents() -> [GeminiUsageEvent] {
        guard let data = try? Data(contentsOf: jsonlURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { line in
            try? decoder.decode(GeminiUsageEvent.self, from: Data(line.utf8))
        }
    }

    private func decimal(_ value: Double) -> String {
        String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func csvEscape(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
