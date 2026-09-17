# Anki Assistant

Ein experimenteller macOS-Lernassistent, der Anki als eigentliche Lernoberfläche beibehält und einen sprachfähigen KI-Tutor ergänzt. Zusätzlich kann die App die aktuell geöffnete Markdown-Notiz aus Obsidian als Gesprächskontext verwenden.

> **Projektstatus:** persönlicher Prototyp in aktiver Entwicklung. Die App ist noch nicht notarisiert und besitzt noch keinen komfortablen Installer für lokale Modelle und Sprachlaufzeiten.

## Funktionen

- liest ausschließlich die Karte, die gerade im Anki-Reviewer sichtbar ist
- deckt die Lösung über AnkiConnect auf und bewertet mit `Erneut`, `Schwer`, `Gut` oder `Einfach`
- führt eine kurze `KI-Notiz` pro Anki-Notiz und hält Knackpunkte fest
- kann sich einen Überblick über den aktuellen Stapel verschaffen, ohne Ankis Lernreihenfolge zu verändern
- unterstützt Gemini Live, eine normale Gemini-Text-API und ein lokales OpenAI-kompatibles Modell
- unterstützt lokale Spracherkennung und Sprachausgabe sowie Unterbrechen beim Lossprechen
- transkribiert Bilder einmalig in Markdown, damit auch reine Textmodelle Bildkarten bearbeiten können
- diskutiert die aktuell geöffnete Obsidian-Notiz, ohne sie automatisch zu verändern
- protokolliert Latenzen und geschätzte API-Kosten

## Architektur und Datenschutz

| Baustein | Ort | Übertragene Daten |
| --- | --- | --- |
| AnkiConnect | lokal | aktuelle Karte, Lösung, Bewertung und KI-Notiz |
| Apple-Spracherkennung | lokal | Mikrofon bleibt auf dem Mac |
| lokales Textmodell | lokal | Karten- oder Dokumentkontext bleibt auf dem Mac |
| lokale TTS | lokal | zu sprechender Antworttext bleibt auf dem Mac |
| Gemini Text-API | Google | erkannter Text, Karten-/Dokumentkontext und gespeicherte Bild-Markdowns |
| Gemini Live | Google | Live-Audio und der für die Sitzung bereitgestellte Kontext |

Originalbilder werden nur übertragen, wenn die Erzeugung fehlender Gemini-Bild-Markdowns ausdrücklich aktiviert ist. Danach verwendet die App den lokalen Markdown-Cache. API-Schlüssel werden im macOS-Schlüsselbund gespeichert und gehören nicht in Konfigurationsdateien oder Git.

## Voraussetzungen

- macOS und ein aktuelles Swift-Toolchain/Xcode Command Line Tools
- Anki Desktop mit installiertem AnkiConnect
- optional: Gemini-API-Schlüssel für Cloud-Modi
- optional: LM Studio oder ein anderer OpenAI-kompatibler lokaler Server auf Port `1234`
- optional: separat installierte lokale Sprach- und Bildmodell-Laufzeiten
- für den Dokumentmodus: Obsidian und das mitgelieferte Bridge-Plugin

`Apple SpeechAnalyzer` benötigt eine unterstützte aktuelle macOS-Version. Auf älteren Systemen kann die kompatible Apple-Spracherkennung gewählt werden.

## Schnellstart

```zsh
git clone https://github.com/whiteshirtbuilds/anki-assistant.git
cd anki-assistant
cp .env.example .env
```

Passe anschließend `.env` an dein System an. Die Datei wird von Git ignoriert und darf weder API-Schlüssel noch andere veröffentlichungsrelevante Geheimnisse enthalten; Gemini-Schlüssel speichert die App selbst im macOS-Schlüsselbund.

```zsh
./make-app.sh
open Anki-Lernassistent.app
```

Öffne in Anki zuerst eine Karte im Reviewer. Danach kann die App über das Menüleistensymbol die aktuelle Karte laden und ein Gespräch starten. Beim ersten Einsatz fragt macOS nach Mikrofon- und Spracherkennungszugriff.

## Konfiguration

Die App sucht die Konfiguration in dieser Reihenfolge:

1. bereits gesetzte Umgebungsvariablen
2. `.env` neben dem Projekt beziehungsweise der App
3. `~/Library/Application Support/Anki-Lernassistent/.env`
4. portable Standardwerte

| Variable | Bedeutung |
| --- | --- |
| `ANKI_ASSISTANT_LOCALAI_ROOT` | Wurzelordner für Modelle, Laufzeiten, Caches und Protokolle |
| `ANKI_ASSISTANT_ANKI_MEDIA` | Medienordner des verwendeten Anki-Profils |
| `ANKI_ASSISTANT_MLX_VLM` | ausführbare `mlx_vlm.generate`-Datei |
| `ANKI_ASSISTANT_VOICE_BRIDGE` | optionaler eigener Ordner der Python-Bridge; beim App-Build wird sie mitgebündelt |
| `ANKI_ASSISTANT_BUNDLE_ID` | lokale App-Kennung; der öffentliche Standard ist `app.whiteshirtbuilds.ankiassistant` |
| `ANKI_ASSISTANT_KEYCHAIN_SERVICE` | Kennung für die im Schlüsselbund gespeicherten Gemini-Schlüssel |
| `ANKI_ASSISTANT_PLUGIN_AUTHOR` | lokal erzeugter Autor-Eintrag des Obsidian-Bridge-Manifests |

Ein Beispiel liegt in [`.env.example`](.env.example). Persönliche Pfade gehören ausschließlich in die ignorierte `.env`.

## Anki-Modus

Die sichtbare Anki-Karte bleibt die verbindliche Quelle. Der Tutor kann über begrenzte Werkzeuge:

- die aktuelle Karte lesen
- die Lösung aufdecken
- den aktuellen Stapel zusammenfassen
- die `KI-Notiz` speichern
- die Karte in Anki bewerten
- ein fehlerhaftes Bild-Markdown neu erstellen oder korrigieren

Die Werkzeuge sind absichtlich auf die aktuelle Karte und den aktuellen Stapel begrenzt. Anki entscheidet weiterhin über Reihenfolge und Wiederholungszeitpunkt.

## Obsidian-Dokumentmodus

1. In den Einstellungen den Arbeitsbereich **Dokument** wählen.
2. Den Obsidian-Vault verbinden.
3. Das mitgelieferte Plugin aus `ObsidianPlugin/anki-lernassistent-bridge` in Obsidian aktivieren.
4. Eine Notiz oder einen Abschnitt öffnen und in der App **Aktive Notiz laden** wählen.

Die Bridge teilt der App lokal nur den Pfad der aktiven Notiz und die aktuelle Auswahl mit. Der Assistent diskutiert den Text und schlägt Änderungen vor, schreibt aber nicht selbstständig in die Markdown-Datei.

## Lokale Bildtranskription

Der optionale Indexer erzeugt Markdown-Beschreibungen für noch nicht bearbeitete Bilder eines Anki-Stapels:

```zsh
./start-image-indexer.sh 'deck:"Mein Stapel"'
```

Er wartet standardmäßig, bis der Mac am Strom hängt und fünf Minuten nicht benutzt wurde. Für einen sofortigen Lauf:

```zsh
./start-image-indexer-now.sh 'deck:"Mein Stapel"'
```

Stoppen:

```zsh
./stop-image-indexer.sh
```

Modell und `mlx_vlm.generate` müssen zuvor über `.env` eingerichtet sein.

## Bekannte Einschränkungen

- kein signierter Release-Download und keine Apple-Notarisierung
- lokale Modelle und Python-Laufzeiten werden noch nicht automatisch installiert
- Modellnamen und Cloud-Preise können sich ändern; die Anzeige in der App ist eine Schätzung
- die Anki-Notiz muss ein Feld namens `KI-Notiz` besitzen, damit Lernhinweise gespeichert werden können
- Gemini-Free-Tier und Kontingente hängen vom verwendeten Google-Projekt ab

## Entwicklung

```zsh
swift build
./make-app.sh
```

Die Anwendung ist eine native Swift-Menüleisten-App. Die lokale Sprachpipeline und die Anki-Werkzeuge liegen in `VoiceBridge/`; das Obsidian-Plugin liegt in `ObsidianPlugin/`.

Fehlerberichte und nachvollziehbare Verbesserungsvorschläge sind willkommen. Bitte keine API-Schlüssel, privaten Kartentexte, Vault-Inhalte oder persönliche Dateipfade in Issues veröffentlichen.

## Lizenz

Für dieses Repository wurde noch keine Open-Source-Lizenz ausgewählt. Solange keine `LICENSE`-Datei vorhanden ist, bleiben alle Rechte vorbehalten. Vor einer breiteren Veröffentlichung oder der Annahme externer Beiträge sollte bewusst eine passende Lizenz gewählt werden.
