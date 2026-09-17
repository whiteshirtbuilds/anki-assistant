import AppKit
import Foundation

enum AssistantWorkspace: String, CaseIterable, Identifiable {
    case anki
    case document

    var id: String { rawValue }

    var label: String {
        switch self {
        case .anki: "Anki"
        case .document: "Dokument"
        }
    }
}

struct ObsidianDocument: Sendable {
    let url: URL
    let vaultName: String
    let title: String
    let markdown: String
    let selectedText: String

    var tutorContext: String {
        let selection = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectionSection = selection.isEmpty
            ? "Keine Textstelle ist markiert."
            : "Markierte Textstelle:\n\(selection)"
        return """
        Aktive Obsidian-Notiz: \(title)
        Vault: \(vaultName)

        \(selectionSection)

        Vollständiger Markdown-Inhalt:
        \(markdown)
        """
    }
}

private struct ObsidianBridgeState: Decodable {
    let vaultPath: String
    let relativePath: String
    let title: String?
    let selectedText: String?
}

enum ObsidianBridgeError: LocalizedError {
    case noContext
    case invalidContext
    case noteMissing
    case unreadableNote

    var errorDescription: String? {
        switch self {
        case .noContext:
            "Obsidian hat noch keine aktive Markdown-Notiz gemeldet. Öffne eine Notiz und aktiviere einmal das Anki-Lernassistent-Plugin in Obsidian."
        case .invalidContext:
            "Die lokale Obsidian-Verbindung enthält keinen gültigen Notizpfad."
        case .noteMissing:
            "Die in Obsidian gemeldete Markdown-Datei wurde nicht gefunden."
        case .unreadableNote:
            "Die aktive Obsidian-Notiz konnte nicht als Markdown gelesen werden."
        }
    }
}

enum ObsidianBridge {
    private static let pluginID = "anki-lernassistent"

    private static var appSupportFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Anki-Lernassistent", isDirectory: true)
    }

    private static var stateURL: URL {
        appSupportFolder.appendingPathComponent("obsidian-context.json")
    }

    @MainActor
    static func installIntoSelectedVault() throws -> String? {
        let panel = NSOpenPanel()
        panel.title = "Obsidian-Vault auswählen"
        panel.message = "Wähle den Ordner deines Obsidian-Vaults. Die Verbindung bleibt vollständig lokal."
        panel.prompt = "Verbinden"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let vaultURL = panel.url else { return nil }
        try install(into: vaultURL)
        return vaultURL.lastPathComponent
    }

    static func loadActiveDocument() throws -> ObsidianDocument {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            throw ObsidianBridgeError.noContext
        }

        let stateData = try Data(contentsOf: stateURL)
        let state: ObsidianBridgeState
        do {
            state = try JSONDecoder().decode(ObsidianBridgeState.self, from: stateData)
        } catch {
            throw ObsidianBridgeError.invalidContext
        }

        let vaultURL = URL(fileURLWithPath: state.vaultPath, isDirectory: true)
            .standardizedFileURL
        let noteURL = vaultURL.appendingPathComponent(state.relativePath).standardizedFileURL
        let vaultPrefix = vaultURL.path.hasSuffix("/") ? vaultURL.path : vaultURL.path + "/"
        guard noteURL.path.hasPrefix(vaultPrefix), noteURL.pathExtension.lowercased() == "md" else {
            throw ObsidianBridgeError.invalidContext
        }
        guard FileManager.default.fileExists(atPath: noteURL.path) else {
            throw ObsidianBridgeError.noteMissing
        }

        let fullMarkdown: String
        do {
            fullMarkdown = try String(contentsOf: noteURL, encoding: .utf8)
        } catch {
            throw ObsidianBridgeError.unreadableNote
        }

        // Sehr große Anhänge würden eine mündliche Diskussion eher verschlechtern
        // und bei Cloud-Modellen unnötige Kosten verursachen.
        let markdown: String
        if fullMarkdown.count > 48_000 {
            markdown = String(fullMarkdown.prefix(48_000))
                + "\n\n[Die Notiz wurde für den Gesprächskontext nach 48.000 Zeichen gekürzt.]"
        } else {
            markdown = fullMarkdown
        }

        return ObsidianDocument(
            url: noteURL,
            vaultName: vaultURL.lastPathComponent,
            title: state.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? state.title!
                : noteURL.deletingPathExtension().lastPathComponent,
            markdown: markdown,
            selectedText: state.selectedText ?? ""
        )
    }

    private static func install(into vaultURL: URL) throws {
        let pluginFolder = vaultURL
            .appendingPathComponent(".obsidian", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(pluginID, isDirectory: true)
        try FileManager.default.createDirectory(at: pluginFolder, withIntermediateDirectories: true)
        try pluginManifest.write(
            to: pluginFolder.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        try pluginSource.write(
            to: pluginFolder.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static var pluginManifest: String {
        let manifest: [String: Any] = [
            "id": "anki-lernassistent",
            "name": "Anki-Lernassistent Bridge",
            "version": "1.0.0",
            "minAppVersion": "1.0.0",
            "description": "Teilt die aktive Markdown-Notiz lokal mit dem Anki-Lernassistenten.",
            "author": AppConfiguration.pluginAuthor,
            "isDesktopOnly": true
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static let pluginSource = """
    const { Plugin, MarkdownView } = require("obsidian");
    const fs = require("fs");
    const path = require("path");
    const os = require("os");

    module.exports = class AnkiLernassistentBridge extends Plugin {
      onload() {
        this.publish = this.publish.bind(this);
        this.registerEvent(this.app.workspace.on("active-leaf-change", this.publish));
        this.registerEvent(this.app.workspace.on("file-open", this.publish));
        this.registerEvent(this.app.workspace.on("editor-change", this.publish));
        this.registerInterval(window.setInterval(this.publish, 900));
        this.publish();
      }

      publish() {
        const file = this.app.workspace.getActiveFile();
        const view = this.app.workspace.getActiveViewOfType(MarkdownView);
        if (!file || !view || !view.editor) return;

        const folder = path.join(os.homedir(), "Library", "Application Support", "Anki-Lernassistent");
        const payload = {
          vaultPath: this.app.vault.adapter.basePath,
          relativePath: file.path,
          title: file.basename,
          selectedText: view.editor.getSelection() || ""
        };
        try {
          fs.mkdirSync(folder, { recursive: true });
          fs.writeFileSync(path.join(folder, "obsidian-context.json"), JSON.stringify(payload), "utf8");
        } catch (_) {
          // Die Bridge bleibt still; der Assistent zeigt einen verständlichen Status an.
        }
      }
    };
    """
}
