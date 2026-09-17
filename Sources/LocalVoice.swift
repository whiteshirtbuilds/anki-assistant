import Foundation
@preconcurrency import AVFoundation
import Speech

enum SpeechInputMode: String, CaseIterable, Identifiable {
    case speechAnalyzer
    case compatible

    var id: String { rawValue }
    var label: String {
        switch self {
        case .speechAnalyzer: "Apple SpeechAnalyzer"
        case .compatible: "Apple kompatibel"
        }
    }
}

enum VoiceOutputMode: String, CaseIterable, Identifiable {
    case qwen3TTS
    case apple

    var id: String { rawValue }
    var label: String {
        switch self {
        case .qwen3TTS: "Qwen3-TTS"
        case .apple: "Apple-Stimme"
        }
    }
}

enum SpeechRateMode: String, CaseIterable, Identifiable {
    case normal
    case fast
    case veryFast

    var id: String { rawValue }
    var label: String {
        switch self {
        case .normal: "Normal"
        case .fast: "Schnell"
        case .veryFast: "Sehr schnell"
        }
    }

    var qwenRate: Float {
        switch self {
        case .normal: 1.0
        case .fast: 1.18
        case .veryFast: 1.35
        }
    }

    var appleRate: Float {
        switch self {
        case .normal: 0.48
        case .fast: 0.55
        case .veryFast: 0.62
        }
    }
}

enum LocalVoiceError: LocalizedError {
    case runtimeMissing
    case modelMissing
    case serverDidNotStart
    case invalidServerResponse
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .runtimeMissing:
            "Die Qwen3-TTS-Laufzeit wurde auf der externen Festplatte nicht gefunden."
        case .modelMissing:
            "Das Qwen3-TTS-Modell wurde auf der externen Festplatte nicht gefunden."
        case .serverDidNotStart:
            "Der lokale Qwen3-TTS-Dienst konnte nicht gestartet werden."
        case .invalidServerResponse:
            "Qwen3-TTS hat keine gültige Audiodatei geliefert."
        case .emptyAudio:
            "Qwen3-TTS hat leeres Audio geliefert."
        }
    }
}

@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    var onStatus: ((String) -> Void)?
    var onPlaybackStateChange: ((Bool) -> Void)?

    private let appleSynthesizer = AVSpeechSynthesizer()
    private let qwenSpeaker = QwenTTSSpeaker()
    private var mode: VoiceOutputMode = .qwen3TTS
    private var rateMode: SpeechRateMode = .fast
    private var speakingTask: Task<Void, Never>?
    private var playbackIsActive = false

    override init() {
        super.init()
        appleSynthesizer.delegate = self
        qwenSpeaker.onPlaybackStateChange = { [weak self] active in
            self?.setPlaybackActive(active)
        }
    }

    func configure(mode: VoiceOutputMode) {
        guard self.mode != mode else { return }
        stop()
        self.mode = mode
        if mode == .apple {
            qwenSpeaker.shutDownServer()
            onStatus?("Apple-Stimme ausgewählt. Qwen3-TTS wurde aus dem Speicher entfernt.")
        } else {
            onStatus?("Qwen3-TTS ausgewählt. Das Modell wird beim ersten Vorlesen von der externen Festplatte geladen.")
        }
    }

    func configure(rateMode: SpeechRateMode) {
        self.rateMode = rateMode
        qwenSpeaker.playbackRate = rateMode.qwenRate
        onStatus?("Sprechtempo „\(rateMode.label)“ ausgewählt.")
    }

    func say(_ text: String) {
        let spokenText = TutorText.forSpeech(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spokenText.isEmpty else { return }
        stopPlaybackOnly()

        if mode == .apple {
            speakWithApple(spokenText)
            return
        }

        onStatus?("Qwen3-TTS bereitet die lokale Sprachausgabe vor …")
        speakingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await qwenSpeaker.say(spokenText)
                guard !Task.isCancelled else { return }
                onStatus?("Qwen3-TTS spricht lokal.")
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                onStatus?("Qwen3-TTS nicht verfügbar: \(error.localizedDescription) Als Ersatz wird die Apple-Stimme verwendet.")
                speakWithApple(spokenText)
            }
        }
    }

    func stop() {
        speakingTask?.cancel()
        speakingTask = nil
        stopPlaybackOnly()
    }

    private func stopPlaybackOnly() {
        appleSynthesizer.stopSpeaking(at: .immediate)
        qwenSpeaker.stopPlayback()
        setPlaybackActive(false)
    }

    private func speakWithApple(_ text: String) {
        appleSynthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "de-DE")
        utterance.rate = rateMode.appleRate
        appleSynthesizer.speak(utterance)
    }

    private func setPlaybackActive(_ active: Bool) {
        guard playbackIsActive != active else { return }
        playbackIsActive = active
        onPlaybackStateChange?(active)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.setPlaybackActive(true) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.setPlaybackActive(false) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.setPlaybackActive(false) }
    }
}

@MainActor
private final class QwenTTSSpeaker: NSObject, AVAudioPlayerDelegate {
    private static let endpoint = URL(string: "http://127.0.0.1:8188/v1/audio/speech")!
    private static let healthEndpoint = URL(string: "http://127.0.0.1:8188/docs")!
    private static var runtimePath: String { AppConfiguration.ttsRuntimeExecutable.path }
    private static var modelPath: String { AppConfiguration.qwenTTSModel.path }
    private static var logFolder: String { AppConfiguration.ttsLogDirectory.path }

    private var player: AVAudioPlayer?
    private var serverProcess: Process?
    var playbackRate: Float = SpeechRateMode.fast.qwenRate
    var onPlaybackStateChange: ((Bool) -> Void)?

    func say(_ text: String) async throws {
        try Task.checkCancellation()
        try await ensureServer()
        try Task.checkCancellation()

        let body: [String: Any] = [
            "model": Self.modelPath,
            "input": text,
            "voice": "Ryan",
            "lang_code": "german",
            "instruct": "Sprich ruhig, freundlich, deutlich und natürlich wie ein geduldiger Tutor.",
            "response_format": "wav",
            "stream": false,
            "temperature": 0.7,
            "top_p": 0.9,
            "top_k": 40,
            "repetition_penalty": 1.05,
            "max_tokens": 2400
        ]
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 330
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw LocalVoiceError.invalidServerResponse
        }
        guard data.count > 44 else { throw LocalVoiceError.emptyAudio }

        let audioPlayer = try AVAudioPlayer(data: data)
        audioPlayer.delegate = self
        audioPlayer.enableRate = true
        audioPlayer.rate = playbackRate
        guard audioPlayer.prepareToPlay() else { throw LocalVoiceError.invalidServerResponse }
        player = audioPlayer
        guard audioPlayer.play() else { throw LocalVoiceError.invalidServerResponse }
        onPlaybackStateChange?(true)
    }

    func stopPlayback() {
        let hadPlayer = player != nil
        player?.stop()
        player = nil
        if hadPlayer { onPlaybackStateChange?(false) }
    }

    func shutDownServer() {
        stopPlayback()
        guard let serverProcess else { return }
        if serverProcess.isRunning { serverProcess.terminate() }
        self.serverProcess = nil
    }

    private func ensureServer() async throws {
        if await serverIsReady() { return }
        guard FileManager.default.isExecutableFile(atPath: Self.runtimePath) else {
            throw LocalVoiceError.runtimeMissing
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: Self.modelPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LocalVoiceError.modelMissing
        }

        if serverProcess?.isRunning != true {
            try FileManager.default.createDirectory(
                atPath: Self.logFolder,
                withIntermediateDirectories: true
            )
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.runtimePath)
            process.arguments = [
                "--host", "127.0.0.1",
                "--port", "8188",
                "--log-dir", Self.logFolder
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            serverProcess = process
        }

        for _ in 0..<120 {
            try Task.checkCancellation()
            if await serverIsReady() { return }
            if serverProcess?.isRunning == false { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw LocalVoiceError.serverDidNotStart
    }

    private func serverIsReady() async -> Bool {
        var request = URLRequest(url: Self.healthEndpoint)
        request.timeoutInterval = 0.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse).map { 200..<500 ~= $0.statusCode } ?? false
        } catch {
            return false
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.player = nil
            self?.onPlaybackStateChange?(false)
        }
    }
}

private final class AnalyzerBufferConverter: @unchecked Sendable {
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(sourceFormat: AVAudioFormat, targetFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else { return nil }
        self.sourceFormat = sourceFormat
        self.targetFormat = targetFormat
        self.converter = converter
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        var conversionError: NSError?
        let input = AnalyzerOneShotAudioInput(buffer)
        let status = converter.convert(to: converted, error: &conversionError) { _, outputStatus in
            guard let buffer = input.take() else {
                outputStatus.pointee = .noDataNow
                return nil
            }
            outputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil, converted.frameLength > 0 else { return nil }
        return converted
    }
}

private final class AnalyzerOneShotAudioInput: @unchecked Sendable {
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

@available(macOS 26.0, *)
@MainActor
final class AppleSpeechAnalyzerService {
    var onTranscript: ((String) -> Void)?
    var onStateChange: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var hasAudioTap = false
    private var wantsToRun = false
    private var generation = UUID()
    private var echoCancellationRequested = false
    private var hasRetriedWithoutEchoCancellation = false

    func start(echoCancellation: Bool = false) {
        guard !wantsToRun else { return }
        wantsToRun = true
        echoCancellationRequested = echoCancellation
        hasRetriedWithoutEchoCancellation = false
        let currentGeneration = UUID()
        generation = currentGeneration
        Task { [weak self] in
            guard let self else { return }
            let speechStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard speechStatus == .authorized else {
                fail("Bitte erlaube dem Anki-Lernassistenten die Spracherkennung in den Systemeinstellungen.")
                return
            }
            let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard microphoneAllowed else {
                fail("Bitte erlaube dem Anki-Lernassistenten den Mikrofonzugriff in den Systemeinstellungen.")
                return
            }
            guard wantsToRun, generation == currentGeneration else { return }
            do {
                try await begin(
                    generation: currentGeneration,
                    echoCancellation: echoCancellation
                )
            } catch {
                recoverWithoutEchoCancellationOrFail(
                    "Apple SpeechAnalyzer konnte nicht gestartet werden: \(error.localizedDescription)",
                    generation: currentGeneration
                )
            }
        }
    }

    func stop() {
        wantsToRun = false
        generation = UUID()
        audioEngine.stop()
        if hasAudioTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasAudioTap = false
        }
        inputContinuation?.finish()
        inputContinuation = nil
        analysisTask?.cancel()
        resultsTask?.cancel()
        analysisTask = nil
        resultsTask = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        echoCancellationRequested = false
        hasRetriedWithoutEchoCancellation = false
        onStateChange?(false)
    }

    private func begin(
        generation currentGeneration: UUID,
        echoCancellation: Bool
    ) async throws {
        stopRunningSessionOnly()
        wantsToRun = true
        generation = currentGeneration

        // Voice processing is useful for barge-in, but is incompatible with
        // some aggregate/external devices. Manual recording never needs it.
        try audioEngine.inputNode.setVoiceProcessingEnabled(echoCancellation)

        guard SpeechTranscriber.isAvailable else {
            throw NSError(domain: "SpeechAnalyzer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Die neue lokale Apple-Spracherkennung ist auf diesem Mac nicht verfügbar."
            ])
        }
        let requestedLocale = Locale(identifier: "de-DE")
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw NSError(domain: "SpeechAnalyzer", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Das deutsche Apple-Sprachmodell wird nicht unterstützt."
            ])
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        guard wantsToRun, generation == currentGeneration else { return }

        let sourceFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            throw NSError(domain: "SpeechAnalyzer", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Das Mikrofon liefert kein verwendbares Audiosignal."
            ])
        }
        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: sourceFormat
        ), let converter = AnalyzerBufferConverter(sourceFormat: sourceFormat, targetFormat: targetFormat) else {
            throw NSError(domain: "SpeechAnalyzer", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Das Mikrofonformat kann nicht für SpeechAnalyzer umgewandelt werden."
            ])
        }

        let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .lingering)
        )
        self.analyzer = analyzer
        inputContinuation = continuation

        resultsTask = Task { [weak self, transcriber] in
            do {
                var finalText = ""
                var volatileText = ""
                for try await result in transcriber.results {
                    guard let self, self.generation == currentGeneration else { return }
                    let part = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        if !part.isEmpty {
                            if part.hasPrefix(finalText) {
                                finalText = part
                            } else if !finalText.hasSuffix(part) {
                                finalText += (finalText.isEmpty ? "" : " ") + part
                            }
                        }
                        volatileText = ""
                    } else {
                        volatileText = part
                    }
                    let combined = [finalText, volatileText]
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    if !combined.isEmpty { self.onTranscript?(combined) }
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.generation == currentGeneration else { return }
                self.recoverWithoutEchoCancellationOrFail(
                    "Apple SpeechAnalyzer wurde beendet: \(error.localizedDescription)",
                    generation: currentGeneration
                )
            }
        }

        analysisTask = Task { [weak self, analyzer] in
            do {
                let lastSample = try await analyzer.analyzeSequence(inputStream)
                if let lastSample {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } catch is CancellationError {
                await analyzer.cancelAndFinishNow()
            } catch {
                guard let self, self.generation == currentGeneration else { return }
                self.recoverWithoutEchoCancellationOrFail(
                    "Apple SpeechAnalyzer konnte das Audio nicht verarbeiten: \(error.localizedDescription)",
                    generation: currentGeneration
                )
            }
        }

        audioEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: sourceFormat) { buffer, _ in
            guard let converted = converter.convert(buffer) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
        hasAudioTap = true
        audioEngine.prepare()
        try audioEngine.start()
        onStateChange?(true)
    }

    private func stopRunningSessionOnly() {
        audioEngine.stop()
        if hasAudioTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasAudioTap = false
        }
        inputContinuation?.finish()
        inputContinuation = nil
        analysisTask?.cancel()
        resultsTask?.cancel()
        analysisTask = nil
        resultsTask = nil
        analyzer = nil
        onStateChange?(false)
    }

    private func fail(_ message: String) {
        stop()
        onError?(message)
    }

    private func recoverWithoutEchoCancellationOrFail(
        _ message: String,
        generation failedGeneration: UUID
    ) {
        guard wantsToRun, generation == failedGeneration else { return }
        guard echoCancellationRequested, !hasRetriedWithoutEchoCancellation else {
            fail(message)
            return
        }

        hasRetriedWithoutEchoCancellation = true
        let retryGeneration = UUID()
        generation = retryGeneration
        Task { [weak self] in
            guard let self, self.wantsToRun, self.generation == retryGeneration else { return }
            do {
                try await self.begin(
                    generation: retryGeneration,
                    echoCancellation: false
                )
            } catch {
                guard self.wantsToRun, self.generation == retryGeneration else { return }
                self.fail("Apple SpeechAnalyzer konnte auch ohne Echo-Unterdrückung nicht gestartet werden: \(error.localizedDescription)")
            }
        }
    }
}
