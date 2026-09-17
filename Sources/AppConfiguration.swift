import Foundation

private struct AppConfigurationFile: Decodable {
    let localAIRoot: String?
    let ankiMediaDirectory: String?
    let mlxVLMExecutable: String?
    let voiceBridgeDirectory: String?
}

enum AppConfiguration {
    private static let environment = ProcessInfo.processInfo.environment
    private static let dotenv = loadDotEnv()
    private static let file = loadConfiguration()
    private static let applicationSupport = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Anki-Lernassistent", isDirectory: true)

    static let localAIRoot = url(
        value("ANKI_ASSISTANT_LOCALAI_ROOT", fallback: file?.localAIRoot),
        fallback: applicationSupport.appendingPathComponent("LocalAI", isDirectory: true)
    )

    static let ankiMediaDirectory = url(
        value("ANKI_ASSISTANT_ANKI_MEDIA", fallback: file?.ankiMediaDirectory),
        fallback: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Anki2/User 1/collection.media", isDirectory: true)
    )

    static let mlxVLMExecutable = url(
        value("ANKI_ASSISTANT_MLX_VLM", fallback: file?.mlxVLMExecutable),
        fallback: URL(fileURLWithPath: "/usr/local/bin/mlx_vlm.generate")
    )

    static let voiceBridgeDirectory: URL = {
        if let configured = value("ANKI_ASSISTANT_VOICE_BRIDGE", fallback: file?.voiceBridgeDirectory),
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return url(configured, fallback: URL(fileURLWithPath: configured))
        }
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("VoiceBridge", isDirectory: true)
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("VoiceBridge", isDirectory: true)
    }()

    static let bundleIdentifier = value("ANKI_ASSISTANT_BUNDLE_ID", fallback: nil)
        ?? "app.whiteshirtbuilds.ankiassistant"
    static let keychainService = value("ANKI_ASSISTANT_KEYCHAIN_SERVICE", fallback: nil)
        ?? "app.whiteshirtbuilds.ankiassistant.gemini"
    static let pluginAuthor = value("ANKI_ASSISTANT_PLUGIN_AUTHOR", fallback: nil)
        ?? "whiteshirtbuilds"
    static var logSubsystem: String { Bundle.main.bundleIdentifier ?? bundleIdentifier }

    static var geminiMarkdownDirectory: URL {
        localAIRoot.appendingPathComponent("anki-image-markdown/gemini", isDirectory: true)
    }

    static var qwenMarkdownDirectory: URL {
        localAIRoot.appendingPathComponent("anki-image-markdown/qwen2_5", isDirectory: true)
    }

    static var speechToSpeechExecutable: URL {
        localAIRoot.appendingPathComponent("runtimes/speech-to-speech/.venv/bin/speech-to-speech")
    }

    static var qwenTTSModel: URL {
        localAIRoot.appendingPathComponent("models/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit", isDirectory: true)
    }

    static var speechCacheDirectory: URL {
        localAIRoot.appendingPathComponent("cache/speech-to-speech", isDirectory: true)
    }

    static var speechLogDirectory: URL {
        localAIRoot.appendingPathComponent("logs/speech-to-speech", isDirectory: true)
    }

    static var ttsRuntimeExecutable: URL {
        localAIRoot.appendingPathComponent("runtimes/anki-lernassistent/.venv_tts/bin/mlx_audio.server")
    }

    static var ttsLogDirectory: URL {
        localAIRoot.appendingPathComponent("logs/anki-lernassistent-tts", isDirectory: true)
    }

    private static func url(_ configured: String?, fallback: URL) -> URL {
        guard let configured, !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
    }

    private static func value(_ key: String, fallback: String?) -> String? {
        let raw = environment[key] ?? dotenv[key] ?? fallback
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return raw
    }

    private static func loadDotEnv() -> [String: String] {
        let fileManager = FileManager.default
        let candidates = [
            URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(".env"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(".env"),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Anki-Lernassistent/.env")
        ]
        guard let candidate = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }),
              let contents = try? String(contentsOf: candidate, encoding: .utf8) else { return [:] }

        var values: [String: String] = [:]
        for originalLine in contents.components(separatedBy: .newlines) {
            var line = originalLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")
                || value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }
            if !key.isEmpty { values[key] = value }
        }
        return values
    }

    private static func loadConfiguration() -> AppConfigurationFile? {
        let fileManager = FileManager.default
        let candidates = [
            URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent("config.local.json"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("config.local.json"),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Anki-Lernassistent/config.json")
        ]
        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            guard let data = try? Data(contentsOf: candidate) else { continue }
            if let configuration = try? JSONDecoder().decode(AppConfigurationFile.self, from: data) {
                return configuration
            }
        }
        return nil
    }
}
