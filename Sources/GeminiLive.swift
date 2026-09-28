import Foundation
@preconcurrency import AVFoundation
import OSLog
import Security

enum TutorMode: String, CaseIterable, Identifiable {
    case local
    case textAPILive
    case geminiLive

    var id: String { rawValue }
    var label: String {
        switch self {
        case .local: "Standard"
        case .textAPILive: "Text-API Live"
        case .geminiLive: "Gemini Live"
        }
    }
}

enum GeminiLiveTier: String, CaseIterable, Identifiable {
    case free
    case paid

    var id: String { rawValue }
    var label: String {
        switch self {
        case .free: "Kostenlos ($0)"
        case .paid: "Bezahlt"
        }
    }
}

enum GeminiKeySlot: Hashable {
    case paid
    case free

    var account: String {
        switch self {
        case .paid: "api-key"
        case .free: "free-api-key"
        }
    }
}

struct GeminiImage: Sendable {
    let name: String
    let mimeType: String
    let data: Data
}

struct GeminiToolArguments: Sendable {
    let note: String?
    let rating: String?
    let deck: String?
    let imageName: String?
    let markdown: String?
}

private final class OneShotAudioInput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        let value = buffer
        buffer = nil
        return value
    }
}

private final class AdaptiveAudioInputConverter: @unchecked Sendable {
    private let lock = NSLock()
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceSampleRate = 0.0
    private var sourceChannelCount: AVAudioChannelCount = 0
    private var sourceCommonFormat: AVAudioCommonFormat = .otherFormat

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> (audio: Data, level: Float)? {
        lock.lock()
        defer { lock.unlock() }

        let source = buffer.format
        if converter == nil ||
            source.sampleRate != sourceSampleRate ||
            source.channelCount != sourceChannelCount ||
            source.commonFormat != sourceCommonFormat {
            converter = AVAudioConverter(from: source, to: targetFormat)
            sourceSampleRate = source.sampleRate
            sourceChannelCount = source.channelCount
            sourceCommonFormat = source.commonFormat
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else { return nil }

        var conversionError: NSError?
        let input = OneShotAudioInput(buffer)
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            guard let buffer = input.take() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, converted.frameLength > 0,
              let samples = converted.int16ChannelData?[0] else { return nil }

        let count = Int(converted.frameLength)
        let audio = Data(bytes: samples, count: count * MemoryLayout<Int16>.size)
        var squaredSum = 0.0
        for index in stride(from: 0, to: count, by: 4) {
            let sample = Double(samples[index]) / Double(Int16.max)
            squaredSum += sample * sample
        }
        let sampledCount = Double((count + 3) / 4)
        let rms = sqrt(squaredSum / sampledCount)
        let decibels = 20 * log10(max(rms, 0.000_001))
        let level = Float(min(1, max(0, (decibels + 60) / 60)))
        return (audio, level)
    }
}

enum GeminiKeyStore {
    private static var service: String { AppConfiguration.keychainService }

    static func load(slot: GeminiKeySlot = .paid) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data,
            let key = String(data: data, encoding: .utf8)
        else { return "" }
        return key
    }

    static func save(_ key: String, slot: GeminiKeySlot = .paid) throws {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot.account
        ]
        let replacement = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(lookup as CFDictionary, replacement as CFDictionary)
        if status == errSecItemNotFound {
            var item = lookup
            item[kSecValueData as String] = Data(key.utf8)
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw GeminiLiveError.keychain(status)
        }
    }
}

enum GeminiLiveError: LocalizedError {
    case missingKey
    case invalidURL
    case keychain(OSStatus)
    case invalidAudio
    case connection(String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            "Bitte trage zuerst deinen Gemini-API-Schlüssel ein."
        case .invalidURL:
            "Die Gemini-Live-Adresse konnte nicht erstellt werden."
        case .keychain(let status):
            "Der API-Schlüssel konnte nicht im Schlüsselbund gespeichert werden (Fehler \(status))."
        case .invalidAudio:
            "Das Mikrofon liefert kein für Gemini verwendbares Audiosignal."
        case .connection(let details):
            "Gemini Live: \(details)"
        }
    }
}

@MainActor
final class GeminiLiveService {
    var onStateChange: ((Bool) -> Void)?
    var onReadyChange: ((Bool) -> Void)?
    var onStatus: ((String) -> Void)?
    var onMicrophoneState: ((_ active: Bool, _ sending: Bool) -> Void)?
    var onInputLevel: ((Float) -> Void)?
    var onSpeechRecognition: ((Bool) -> Void)?
    var onInputTranscript: ((String) -> Void)?
    var onOutputTranscript: ((String) -> Void)?
    var onToolCall: ((String, GeminiToolArguments) async -> [String: String])?
    var onUsage: ((GeminiUsageMetadata, Double, Double) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let audioLogger = Logger(
        subsystem: AppConfiguration.logSubsystem,
        category: "GeminiAudio"
    )
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var inputTapInstalled = false
    private var inputTranscript = ""
    private var outputTranscript = ""
    private var pendingImages: [GeminiImage] = []
    private var pendingPlayback = Data()
    private let playbackChunkBytes = 9_600 // 200 ms PCM16 mono at 24 kHz
    private var suppressMicrophone = false {
        didSet {
            guard oldValue != suppressMicrophone else { return }
            publishMicrophoneState()
        }
    }
    private var microphoneResumeTask: Task<Void, Never>?
    private var inputAudioBytesSinceUsage = 0
    private var outputAudioBytesSinceUsage = 0
    private var initialGreetingSent = false
    private var workspace: AssistantWorkspace = .anki

    var isActive: Bool { socket != nil }

    func start(
        apiKey: String,
        instruction: String,
        images: [GeminiImage] = [],
        workspace: AssistantWorkspace = .anki
    ) {
        stop()
        self.workspace = workspace
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            onStatus?(GeminiLiveError.missingKey.localizedDescription)
            return
        }

        var components = URLComponents()
        components.scheme = "wss"
        components.host = "generativelanguage.googleapis.com"
        components.path = "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        components.queryItems = [URLQueryItem(name: "key", value: trimmedKey)]
        guard let url = components.url else {
            onStatus?(GeminiLiveError.invalidURL.localizedDescription)
            return
        }

        inputTranscript = ""
        outputTranscript = ""
        suppressMicrophone = false
        pendingImages = Array(images.prefix(8))
        inputAudioBytesSinceUsage = 0
        outputAudioBytesSinceUsage = 0
        initialGreetingSent = false
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        socket = task
        task.resume()
        onStateChange?(true)
        onReadyChange?(false)
        onStatus?("Verbinde mit Gemini Live …")

        var setup: [String: Any] = [
            "setup": [
                "model": "models/gemini-3.1-flash-live-preview",
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "speechConfig": [
                        "voiceConfig": [
                            "prebuiltVoiceConfig": ["voiceName": "Kore"]
                        ]
                    ],
                    "thinkingConfig": ["thinkingLevel": "minimal"]
                ],
                "systemInstruction": [
                    "parts": [["text": instruction]]
                ],
                "tools": [[
                    "functionDeclarations": [
                        [
                            "name": "read_current_anki_card",
                            "description": "Verbindliche und maßgebliche Kartenquelle: Liest ausschließlich die Karte, die gerade im Anki-Lernfenster sichtbar ist, und liefert Karten-ID, Frage, Lösung und vorhandene KI-Notiz. Vor jeder neuen Karte aufrufen, außer rate_anki_card hat die nächste Karte unmittelbar im Ergebnis geliefert. Niemals selbst eine Karte oder Reihenfolge erfinden."
                        ],
                        [
                            "name": "get_deck_overview",
                            "description": "Übersicht verschaffen: Liest alle Karten des aktuellen Anki-Stapels, ohne die sichtbare Karte oder die Lernreihenfolge zu verändern. Verwende es einmal, wenn ein neues Thema beginnt oder die lernende Person einen Überblick wünscht. Fasse anschließend kurz die Teilthemen und den roten Faden zusammen.",
                            "parameters": [
                                "type": "OBJECT",
                                "properties": [
                                    "deck": [
                                        "type": "STRING",
                                        "description": "Optionaler exakter Anki-Stapelname. Ohne Angabe wird der Stapel der zuvor gelesenen aktuellen Karte verwendet."
                                    ]
                                ]
                            ]
                        ],
                        [
                            "name": "update_image_markdown",
                            "description": "Bild-Markdown korrigieren: Ersetzt das gespeicherte Gemini-Transkript eines Bildes der aktuell geöffneten Karte durch ein vollständiges, korrigiertes Markdown. Ausschließlich verwenden, wenn die lernende Person ausdrücklich einen Einlesefehler nennt oder eine Korrektur verlangt. Nie nur einen Teil-Patch speichern; die vollständige korrigierte Fassung übergeben. Die vorherige Fassung wird automatisch gesichert.",
                            "parameters": [
                                "type": "OBJECT",
                                "properties": [
                                    "image_name": [
                                        "type": "STRING",
                                        "description": "Exakter Dateiname des Bildes der aktuellen Karte."
                                    ],
                                    "markdown": [
                                        "type": "STRING",
                                        "description": "Vollständiges korrigiertes Markdown für dieses Bild."
                                    ]
                                ],
                                "required": ["image_name", "markdown"]
                            ]
                        ],
                        [
                            "name": "reanalyze_image_markdown",
                            "description": "Bild neu einlesen: Sendet das Originalbild der aktuell geöffneten Anki-Karte erneut an Gemini, erstellt ein frisches vollständiges Markdown und ersetzt das bisherige Gemini-Transkript. Nur verwenden, wenn die lernende Person ausdrücklich sagt, dass das Bild neu eingelesen werden soll. Die vorherige Fassung wird automatisch gesichert.",
                            "parameters": [
                                "type": "OBJECT",
                                "properties": [
                                    "image_name": [
                                        "type": "STRING",
                                        "description": "Exakter Dateiname des Bildes der aktuellen Karte, das neu eingelesen werden soll."
                                    ]
                                ],
                                "required": ["image_name"]
                            ]
                        ],
                        [
                            "name": "show_anki_answer",
                            "description": "Deckt die Lösung der aktuellen Karte direkt im Anki-Lernfenster auf."
                        ],
                        [
                            "name": "save_anki_ai_note",
                            "description": "Speichert eine kurze Lernstandsnotiz im Feld KI-Notiz der aktuellen Anki-Notiz.",
                            "parameters": [
                                "type": "OBJECT",
                                "properties": [
                                    "note": [
                                        "type": "STRING",
                                        "description": "Kurze Notiz im Format: Status – konkreter Knackpunkt – nächster Schritt."
                                    ]
                                ],
                                "required": ["note"]
                            ]
                        ],
                        [
                            "name": "rate_anki_card",
                            "description": "Bewertet die aktuelle Anki-Karte. Ausschließlich Anki wählt und öffnet danach über seinen Lernplaner die nächste Karte; das Werkzeug liefert diese tatsächlich sichtbare nächste Karte samt Karten-ID zurück. Nur nach einer Antwort des Lernenden oder auf ausdrücklichen Wunsch verwenden. Niemals selbst eine Folgekarte erzeugen.",
                            "parameters": [
                                "type": "OBJECT",
                                "properties": [
                                    "rating": [
                                        "type": "STRING",
                                        "enum": ["again", "hard", "good", "easy"],
                                        "description": "again=Erneut, hard=Schwer, good=Gut, easy=Einfach"
                                    ]
                                ],
                                "required": ["rating"]
                            ]
                        ]
                    ]
                ]],
                "realtimeInputConfig": [
                    "automaticActivityDetection": [
                        "disabled": false,
                        "startOfSpeechSensitivity": "START_SENSITIVITY_HIGH",
                        "prefixPaddingMs": 300,
                        "endOfSpeechSensitivity": "END_SENSITIVITY_LOW",
                        "silenceDurationMs": 800
                    ]
                ],
                "inputAudioTranscription": [:],
                "outputAudioTranscription": [:]
            ]
        ]
        if workspace == .document,
           var configuration = setup["setup"] as? [String: Any] {
            configuration.removeValue(forKey: "tools")
            setup["setup"] = configuration
        }
        sendJSON(setup)
        beginReceiveLoop(task)
    }

    func stop() {
        audioLogger.info("Gemini-Live-Audio wird beendet.")
        player.stop()
        pendingPlayback.removeAll(keepingCapacity: true)
        suppressMicrophone = false
        microphoneResumeTask?.cancel()
        microphoneResumeTask = nil
        stopInput()
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        pendingImages = []
        initialGreetingSent = false
        onInputLevel?(0)
        onSpeechRecognition?(false)
        onMicrophoneState?(false, false)
        onStateChange?(false)
        onReadyChange?(false)
        audioLogger.info("Gemini-Live-Audio wurde vollständig beendet.")
    }

    private func beginReceiveLoop(_ task: URLSessionWebSocketTask) {
        receiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    guard let self else { return }
                    self.handle(message)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.socket === task else { return }
                self.fail("Verbindung beendet: \(error.localizedDescription)")
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let value): data = value
        @unknown default: return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if json["setupComplete"] != nil {
            onReadyChange?(true)
            sendPendingImagesAndStartInput()
            return
        }

        if let server = json["serverContent"] as? [String: Any] {
            if let transcription = server["interimInputTranscription"] as? [String: Any],
               let text = transcription["text"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                inputTranscript = text.trimmingCharacters(in: .whitespacesAndNewlines)
                onSpeechRecognition?(true)
                onInputTranscript?(inputTranscript)
            }
            if let transcription = server["inputTranscription"] as? [String: Any],
               let text = transcription["text"] as? String {
                // Gemini sends revised/final transcript snapshots. Appending every
                // snapshot produces repetitions such as "Sie / Sie zeigt / Sie zeigt …".
                inputTranscript = text.trimmingCharacters(in: .whitespacesAndNewlines)
                onSpeechRecognition?(!inputTranscript.isEmpty)
                onInputTranscript?(inputTranscript)
            }
            if let transcription = server["outputTranscription"] as? [String: Any],
               let text = transcription["text"] as? String {
                // Keep the newest snapshot for the current model turn instead of
                // concatenating intermediate hypotheses.
                outputTranscript = text.trimmingCharacters(in: .whitespacesAndNewlines)
                onOutputTranscript?(outputTranscript)
            }
            if let modelTurn = server["modelTurn"] as? [String: Any],
               let parts = modelTurn["parts"] as? [[String: Any]] {
                var receivedAudio = false
                for part in parts {
                    guard
                        let inline = part["inlineData"] as? [String: Any],
                        let encoded = inline["data"] as? String,
                        let audio = Data(base64Encoded: encoded)
                    else { continue }
                    receivedAudio = true
                    play(audio)
                }
                if receivedAudio {
                    onSpeechRecognition?(false)
                    suppressMicrophone = true
                    microphoneResumeTask?.cancel()
                }
            }
            if server["interrupted"] as? Bool == true {
                player.stop()
                pendingPlayback.removeAll(keepingCapacity: true)
                suppressMicrophone = false
                onStatus?("Unterbrochen – Gemini hört dir zu.")
            } else {
                if server["generationComplete"] as? Bool == true {
                    flushPendingPlayback()
                }
                if server["turnComplete"] as? Bool == true {
                    flushPendingPlayback()
                    resumeMicrophoneAfterPlayback()
                    onStatus?("Gemini Live hört weiter zu.")
                }
            }
        }

        if let toolCall = json["toolCall"] as? [String: Any] {
            handleToolCall(toolCall)
        }

        if let goAway = json["goAway"] as? [String: Any] {
            let remaining = goAway["timeLeft"] as? String ?? "bald"
            onStatus?("Die Live-Sitzung endet \(remaining). Starte sie danach neu.")
        }

        if let rawUsage = json["usageMetadata"] as? [String: Any],
           let usage = GeminiUsageMetadata.decode(rawUsage) {
            let inputSeconds = Double(inputAudioBytesSinceUsage) / (16_000 * 2)
            let outputSeconds = Double(outputAudioBytesSinceUsage) / (24_000 * 2)
            inputAudioBytesSinceUsage = 0
            outputAudioBytesSinceUsage = 0
            onUsage?(usage, inputSeconds, outputSeconds)
        }
    }

    private func sendPendingImagesAndStartInput() {
        let images = pendingImages
        pendingImages = []
        Task { [weak self] in
            guard let self else { return }
            if !images.isEmpty {
                self.onStatus?("Übertrage \(images.count) Kartenbild\(images.count == 1 ? "" : "er") an Gemini …")
                for (index, image) in images.enumerated() {
                    guard self.socket != nil else { return }
                    self.sendJSON([
                        "realtimeInput": [
                            "video": [
                                "data": image.data.base64EncodedString(),
                                "mimeType": image.mimeType
                            ]
                        ]
                    ])
                    if index < images.count - 1 {
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
            }
            do {
                try self.startInput()
                self.sendInitialGreeting()
            } catch {
                self.audioLogger.error("Audio-Engine konnte nicht starten: \(error.localizedDescription, privacy: .public)")
                self.fail(error.localizedDescription)
            }
        }
    }

    private func sendInitialGreeting() {
        guard !initialGreetingSent else { return }
        initialGreetingSent = true
        suppressMicrophone = true
        onStatus?("Gemini ist bereit und begrüßt dich …")
        let greeting = workspace == .document
            ? """
              Die Live-Verbindung ist bereit. Begrüße mich kurz und nenne in einem Satz das Thema der geladenen Obsidian-Notiz. Warte danach auf meine Frage zur Bachelorarbeit. Behandle die Notiz als Dokument, nicht als Lernkarte.
              """
            : """
              Die Live-Verbindung ist jetzt vollständig bereit. Rufe zuerst read_current_anki_card auf. Begrüße mich danach kurz und sage in höchstens zwei Sätzen konkret, worum es auf der aktuell geöffneten Karte geht, ohne die vollständige Lösung vorwegzunehmen. Wenn ich „Starte neues Thema“ oder „Gib mir einen Themenüberblick“ sage, rufe get_deck_overview auf und gib einen Überblick über das Thema dieses Stapels mit höchstens fünf kurzen Punkten. Beende mit: Du kannst loslegen.
              """
        sendJSON(["realtimeInput": ["text": greeting]])
    }

    private func startInput() throws {
        guard !inputTapInstalled else { return }
        let input = audioEngine.inputNode
        guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
              ) else { throw GeminiLiveError.invalidAudio }

        guard let playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        ) else { throw GeminiLiveError.invalidAudio }
        if !audioEngine.attachedNodes.contains(player) {
            audioEngine.attach(player)
            audioEngine.connect(player, to: audioEngine.mainMixerNode, format: playbackFormat)
        }

        // On some Macs the input and output sides of the shared audio graph use
        // different sample rates (for example 16 kHz input and 44.1 kHz output).
        // A nil tap format follows the graph's output rate and AVFAudio then
        // rejects the tap with error -10868. Bind the tap to the hardware-facing
        // input format and convert its buffers to Gemini's 16 kHz stream below.
        let hardwareInputFormat = input.inputFormat(forBus: 0)
        guard hardwareInputFormat.sampleRate > 0,
              hardwareInputFormat.channelCount > 0 else {
            throw GeminiLiveError.invalidAudio
        }
        let converter = AdaptiveAudioInputConverter(targetFormat: targetFormat)
        input.installTap(onBus: 0, bufferSize: 1024, format: hardwareInputFormat) { [weak self] buffer, _ in
            guard let converted = converter.convert(buffer) else { return }
            Task { @MainActor [weak self] in
                self?.sendAudio(converted.audio, inputLevel: converted.level)
            }
        }
        inputTapInstalled = true
        audioEngine.prepare()
        try audioEngine.start()
        let graphFormat = input.outputFormat(forBus: 0)
        audioLogger.info(
            "Gemini-Audio gestartet: Hardware-Eingang \(hardwareInputFormat.sampleRate, privacy: .public) Hz / \(hardwareInputFormat.channelCount, privacy: .public) Kanal/Kanäle; Audio-Graph \(graphFormat.sampleRate, privacy: .public) Hz"
        )
        publishMicrophoneState()
    }

    private func stopInput() {
        audioEngine.stop()
        if inputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        onInputLevel?(0)
        onSpeechRecognition?(false)
        publishMicrophoneState()
    }

    private func sendAudio(_ data: Data, inputLevel: Float) {
        onInputLevel?(inputLevel)
        guard !suppressMicrophone else { return }
        inputAudioBytesSinceUsage += data.count
        sendJSON([
            "realtimeInput": [
                "audio": [
                    "data": data.base64EncodedString(),
                    "mimeType": "audio/pcm;rate=16000"
                ]
            ]
        ])
    }

    private func publishMicrophoneState() {
        let active = inputTapInstalled && audioEngine.isRunning
        onMicrophoneState?(active, active && !suppressMicrophone)
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        let activeSocket = socket
        Task { [weak self] in
            do {
                try await activeSocket.send(.string(text))
            } catch {
                guard let self, self.socket === activeSocket else { return }
                self.fail("Senden fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }

    private func resumeMicrophoneAfterPlayback() {
        microphoneResumeTask?.cancel()
        microphoneResumeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.suppressMicrophone = false
            self.microphoneResumeTask = nil
        }
    }

    private func handleToolCall(_ toolCall: [String: Any]) {
        guard workspace == .anki else { return }
        guard let calls = toolCall["functionCalls"] as? [[String: Any]], !calls.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            var responses: [[String: Any]] = []
            for call in calls {
                guard
                    let id = call["id"] as? String,
                    let name = call["name"] as? String
                else { continue }
                let rawArguments = call["args"] as? [String: Any] ?? [:]
                let arguments = GeminiToolArguments(
                    note: rawArguments["note"] as? String,
                    rating: rawArguments["rating"] as? String,
                    deck: rawArguments["deck"] as? String,
                    imageName: rawArguments["image_name"] as? String,
                    markdown: rawArguments["markdown"] as? String
                )
                let result = await self.onToolCall?(name, arguments) ?? [
                    "status": "error",
                    "message": "Dieses Werkzeug ist in der App nicht verbunden."
                ]
                responses.append([
                    "id": id,
                    "name": name,
                    "response": ["result": result]
                ])
            }
            guard !responses.isEmpty else { return }
            self.sendJSON([
                "toolResponse": ["functionResponses": responses]
            ])
        }
    }

    private func play(_ data: Data) {
        guard !data.isEmpty else { return }
        outputAudioBytesSinceUsage += data.count
        pendingPlayback.append(data)
        while pendingPlayback.count >= playbackChunkBytes {
            let chunk = Data(pendingPlayback.prefix(playbackChunkBytes))
            pendingPlayback.removeFirst(playbackChunkBytes)
            schedulePlayback(chunk)
        }
    }

    private func flushPendingPlayback() {
        guard !pendingPlayback.isEmpty else { return }
        let remainder = pendingPlayback
        pendingPlayback.removeAll(keepingCapacity: true)
        schedulePlayback(remainder)
    }

    private func schedulePlayback(_ data: Data) {
        guard !data.isEmpty,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 24_000,
                channels: 1,
                interleaved: true
              ) else { return }

        if !audioEngine.isRunning {
            audioEngine.prepare()
            try? audioEngine.start()
        }

        let frames = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.int16ChannelData?[0] else { return }
        buffer.frameLength = frames
        data.copyBytes(to: UnsafeMutableRawBufferPointer(start: samples, count: data.count))
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
    }

    private func fail(_ details: String) {
        onStatus?(GeminiLiveError.connection(details).localizedDescription)
        stop()
    }
}
