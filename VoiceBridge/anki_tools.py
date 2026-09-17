"""AnkiConnect tools for the local speech-to-speech tutor.

The voice pipeline runs on the external disk, while all mutations stay scoped
to the card that is actually visible in Anki's reviewer.
"""

from __future__ import annotations

import asyncio
import hashlib
import html
import json
import os
import re
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


def _dotenv() -> dict[str, str]:
    candidates = [
        Path(__file__).resolve().parents[1] / ".env",
        Path.home() / "Library/Application Support/Anki-Lernassistent/.env",
    ]
    for candidate in candidates:
        try:
            lines = candidate.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        values: dict[str, str] = {}
        for original in lines:
            line = original.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            if line.startswith("export "):
                line = line[len("export "):]
            key, value = line.split("=", 1)
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            values[key.strip()] = value
        return values
    return {}


def _configuration() -> dict[str, Any]:
    candidates = [
        Path(__file__).resolve().parents[1] / "config.local.json",
        Path.home() / "Library/Application Support/Anki-Lernassistent/config.json",
    ]
    for candidate in candidates:
        try:
            return json.loads(candidate.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
    return {}


_DOTENV = _dotenv()
_CONFIG = _configuration()
_LOCAL_AI_ROOT = Path(
    os.environ.get("ANKI_ASSISTANT_LOCALAI_ROOT")
    or _DOTENV.get("ANKI_ASSISTANT_LOCALAI_ROOT")
    or _CONFIG.get("localAIRoot")
    or Path.home() / "Library/Application Support/Anki-Lernassistent/LocalAI"
).expanduser()
ANKI_CONNECT_URL = "http://127.0.0.1:8765"
GEMINI_MARKDOWN = _LOCAL_AI_ROOT / "anki-image-markdown/gemini"
QWEN_MARKDOWN = _LOCAL_AI_ROOT / "anki-image-markdown/qwen2_5"
ANKI_MEDIA = Path(
    os.environ.get("ANKI_ASSISTANT_ANKI_MEDIA")
    or _DOTENV.get("ANKI_ASSISTANT_ANKI_MEDIA")
    or _CONFIG.get("ankiMediaDirectory")
    or Path.home() / "Library/Application Support/Anki2/User 1/collection.media"
).expanduser()
MARKDOWN_PROMPT_VERSION = "anki-lossless-image-markdown-v1"


TOOLS = [
    {
        "type": "function",
        "name": "read_current_anki_card",
        "description": (
            "Liest ausschließlich die Karte, die gerade im Anki-Lernfenster sichtbar ist. "
            "Dies ist die verbindliche Quelle für Frage, Lösung, Kartenreihenfolge und Bildinhalt. "
            "Vor jeder Erklärung oder neuen Karte aufrufen."
        ),
        "parameters": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "type": "function",
        "name": "get_deck_overview",
        "description": (
            "Übersicht verschaffen: Liest alle Karten des aktuellen Anki-Stapels, ohne die sichtbare Karte "
            "oder die Lernreihenfolge zu verändern. Einmal einsetzen, wenn ein neues Thema beginnt oder "
            "ein Überblick gewünscht wird; danach die Teilthemen und den roten Faden kurz zusammenfassen."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "deck": {
                    "type": "string",
                    "description": "Optionaler exakter Anki-Stapelname. Ohne Angabe wird der Stapel der sichtbaren Karte verwendet.",
                }
            },
            "additionalProperties": False,
        },
    },
    {
        "type": "function",
        "name": "update_image_markdown",
        "description": (
            "Korrigiert ein gespeichertes Gemini-Bildtranskript für ein Bild der aktuell sichtbaren Karte. "
            "Nur bei ausdrücklichem Korrekturwunsch verwenden. Der Wert markdown muss immer die vollständige "
            "korrigierte Fassung sein, nie nur ein Teil-Patch. Die vorherige Fassung wird gesichert."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "image_name": {
                    "type": "string",
                    "description": "Exakter Bilddateiname aus image_names der aktuellen Karte.",
                },
                "markdown": {
                    "type": "string",
                    "description": "Vollständiges korrigiertes Markdown für das Bild.",
                },
            },
            "required": ["image_name", "markdown"],
            "additionalProperties": False,
        },
    },
    {
        "type": "function",
        "name": "show_anki_answer",
        "description": "Deckt die Lösung der gerade sichtbaren Karte direkt in Anki auf.",
        "parameters": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "type": "function",
        "name": "save_anki_ai_note",
        "description": (
            "Speichert den Lernstand im Feld KI-Notiz der gerade sichtbaren Anki-Notiz. "
            "Vor einer Bewertung verwenden."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "note": {
                    "type": "string",
                    "description": "Kurzformat: Status – konkreter Knackpunkt – nächster Schritt.",
                }
            },
            "required": ["note"],
            "additionalProperties": False,
        },
    },
    {
        "type": "function",
        "name": "rate_anki_card",
        "description": (
            "Bewertet die aktuelle Karte in Anki. Anki wählt danach selbst die nächste fällige Karte; "
            "das Werkzeug liefert genau diese anschließend sichtbare Karte zurück."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "rating": {
                    "type": "string",
                    "enum": ["again", "hard", "good", "easy"],
                    "description": "again=Erneut, hard=Schwer, good=Gut, easy=Einfach",
                }
            },
            "required": ["rating"],
            "additionalProperties": False,
        },
    },
]


def _invoke_sync(action: str, params: dict[str, Any]) -> Any:
    payload = json.dumps({"action": action, "version": 6, "params": params}).encode()
    request = urllib.request.Request(
        ANKI_CONNECT_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            decoded = json.loads(response.read())
    except (urllib.error.URLError, TimeoutError) as exc:
        raise RuntimeError("AnkiConnect ist nicht erreichbar. Ist Anki geöffnet?") from exc
    if decoded.get("error"):
        raise RuntimeError(str(decoded["error"]))
    return decoded.get("result")


async def _invoke(action: str, params: dict[str, Any]) -> Any:
    return await asyncio.to_thread(_invoke_sync, action, params)


def _clean_html(value: str) -> str:
    value = re.sub(r"(?is)<(style|script)[^>]*>.*?</\1>", "", value)
    value = re.sub(r"(?i)<br\s*/?>", "\n", value)
    value = re.sub(r"(?i)</(div|p|li|tr|h[1-6])>", "\n", value)
    value = re.sub(r"<[^>]+>", "", value)
    value = html.unescape(value).replace("\xa0", " ")
    value = re.sub(r"[ \t]+", " ", value)
    return re.sub(r"\n{3,}", "\n\n", value).strip()


def _image_names(card_html: str) -> list[str]:
    names = re.findall(r'''(?i)<img[^>]+src=["']([^"']+)["']''', card_html)
    return sorted({Path(html.unescape(name)).name for name in names})


def _markdown_index(folder: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    if not folder.is_dir():
        return result
    for metadata_path in folder.glob("*.json"):
        try:
            metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
            image_name = Path(str(metadata["image"])).name
            markdown_name = str(metadata["markdown"])
            markdown_path = folder / markdown_name
            if markdown_path.is_file():
                result[image_name] = markdown_path.read_text(encoding="utf-8")
        except (KeyError, OSError, ValueError, TypeError):
            continue
    return result


def _visual_context(card_html: str) -> str:
    wanted = _image_names(card_html)
    if not wanted:
        return "Kein Bild auf dieser Karte."
    gemini = _markdown_index(GEMINI_MARKDOWN)
    qwen = _markdown_index(QWEN_MARKDOWN)
    sections: list[str] = []
    used = 0
    for image_name in wanted:
        markdown = gemini.get(image_name) or qwen.get(image_name)
        if not markdown:
            sections.append(f"Bild {image_name}: Noch kein Bildtranskript vorhanden.")
            continue
        remaining = 16_000 - used
        if remaining <= 0:
            break
        markdown = markdown[:remaining]
        source = "Gemini-Markdown" if image_name in gemini else "lokales Qwen-Markdown"
        sections.append(f"Bild {image_name} ({source}):\n{markdown}")
        used += len(markdown)
    return "\n\n".join(sections)


async def _current_card() -> dict[str, Any]:
    current = await _invoke("guiCurrentCard", {})
    if not current:
        raise RuntimeError("In Anki ist gerade keine Karte im Lernmodus geöffnet.")
    card_id = int(current["cardId"])
    cards = await _invoke("cardsInfo", {"cards": [card_id]})
    if not cards:
        raise RuntimeError("Anki konnte die sichtbare Karte nicht lesen.")
    fields = {name: item.get("value", "") for name, item in cards[0].get("fields", {}).items()}
    question_html = str(current.get("question", ""))
    answer_html = str(current.get("answer", ""))
    return {
        "status": "success",
        "source": "AnkiConnect guiCurrentCard",
        "card_id": card_id,
        "note_id": int(cards[0]["note"]),
        "deck": str(cards[0].get("deckName", "")),
        "question": _clean_html(question_html),
        "solution": _clean_html(answer_html),
        "ki_note": fields.get("KI-Notiz", ""),
        "image_names": _image_names(question_html + "\n" + answer_html),
        "visual_context": _visual_context(question_html + "\n" + answer_html),
    }


def _overview_fields(fields: dict[str, Any]) -> list[str]:
    ignored = {"ki-notiz", "ki notiz", "tags"}
    priority = [
        "Front", "Frage", "Question", "Vorderseite",
        "Back", "Antwort", "Answer", "Rückseite", "Extra", "Erklärung",
    ]
    ordered = sorted(
        fields,
        key=lambda name: (priority.index(name) if name in priority else len(priority), name.casefold()),
    )
    result: list[str] = []
    for name in ordered:
        if name.casefold() in ignored:
            continue
        value = _clean_html(str(fields[name].get("value", "")))
        if value:
            result.append(f"{name}: {value}")
    return result


async def _deck_overview(deck: str | None) -> dict[str, Any]:
    current: dict[str, Any] | None = None
    clean_deck = (deck or "").strip()
    if not clean_deck:
        current = await _current_card()
        clean_deck = str(current.get("deck", "")).strip()
    if not clean_deck:
        raise RuntimeError("Für die Übersicht fehlt der Stapelname. Lies zuerst die aktuelle Anki-Karte.")

    escaped_deck = clean_deck.replace('"', r'\"')
    card_ids = await _invoke("findCards", {"query": f'deck:"{escaped_deck}"'})
    if not card_ids:
        raise RuntimeError(f"Im Stapel „{clean_deck}“ wurden keine Karten gefunden.")

    unique_notes: list[dict[str, Any]] = []
    seen_note_ids: set[int] = set()
    for start in range(0, len(card_ids), 100):
        infos = await _invoke("cardsInfo", {"cards": card_ids[start:start + 100]})
        for info in infos:
            note_id = int(info["note"])
            if note_id not in seen_note_ids:
                seen_note_ids.add(note_id)
                unique_notes.append(info)

    gemini_index = _markdown_index(GEMINI_MARKDOWN)
    qwen_index = _markdown_index(QWEN_MARKDOWN)
    max_total = 96_000
    max_per_note = 1_400
    parts: list[str] = []
    used = 0
    truncated = False
    for index, info in enumerate(unique_notes, start=1):
        fields = info.get("fields", {})
        field_lines = _overview_fields(fields)
        raw_html = "\n".join(str(item.get("value", "")) for item in fields.values())
        image_lines: list[str] = []
        for image_name in _image_names(raw_html):
            markdown = gemini_index.get(image_name) or qwen_index.get(image_name)
            if markdown:
                image_lines.append(f"Bild {image_name}:\n{markdown[:900]}")
        item = f"Karte {index}:\n" + "\n".join(field_lines + image_lines) + "\n\n"
        if len(item) > max_per_note:
            item = item[:max_per_note] + " …\n\n"
        if used + len(item) > max_total:
            truncated = True
            break
        parts.append(item)
        used += len(item)

    if len(parts) < len(unique_notes):
        truncated = True
    return {
        "status": "success",
        "source": "AnkiConnect findCards + cardsInfo",
        "message": "Stapelübersicht wurde gelesen, ohne Ankis Lernreihenfolge zu verändern.",
        "deck": str(unique_notes[0].get("deckName", clean_deck)) if unique_notes else clean_deck,
        "card_count": len(card_ids),
        "note_count": len(unique_notes),
        "included_note_count": len(parts),
        "truncated": truncated,
        "deck_content": "".join(parts),
    }


def _replace_gemini_markdown(image_name: str, markdown: str) -> str:
    clean_name = Path(str(image_name)).name
    if clean_name != image_name or not clean_name:
        raise ValueError("Der Bildname ist ungültig.")
    cleaned_markdown = str(markdown).strip()
    if not cleaned_markdown:
        raise ValueError("Das korrigierte Markdown darf nicht leer sein.")
    if len(cleaned_markdown) > 64_000:
        raise ValueError("Das korrigierte Markdown ist zu lang.")

    image_path = ANKI_MEDIA / clean_name
    if not image_path.is_file():
        raise RuntimeError("Das Bild der aktuellen Anki-Karte wurde nicht gefunden.")
    image_data = image_path.read_bytes()
    image_hash = hashlib.sha256(image_data).hexdigest()
    markdown_path = GEMINI_MARKDOWN / f"{image_hash}.md"
    metadata_path = GEMINI_MARKDOWN / f"{image_hash}.json"
    GEMINI_MARKDOWN.mkdir(parents=True, exist_ok=True)

    if markdown_path.is_file():
        revisions = GEMINI_MARKDOWN / "revisions"
        revisions.mkdir(parents=True, exist_ok=True)
        revision = f"{image_hash}-{int(time.time())}"
        (revisions / f"{revision}.md").write_bytes(markdown_path.read_bytes())
        if metadata_path.is_file():
            (revisions / f"{revision}.json").write_bytes(metadata_path.read_bytes())

    markdown_path.write_text(cleaned_markdown + "\n", encoding="utf-8")
    metadata = {
        "image": clean_name,
        "sourceSHA256": image_hash,
        "markdown": markdown_path.name,
        "model": "Gemini-Transkript, manuell durch Tutor korrigiert",
        "promptVersion": MARKDOWN_PROMPT_VERSION,
        "createdAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    metadata_path.write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return f"Gemini-Markdown für {clean_name} wurde korrigiert. Die vorherige Fassung liegt im Ordner revisions."


async def execute_tool(name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    if name == "read_current_anki_card":
        return await _current_card()

    if name == "get_deck_overview":
        return await _deck_overview(arguments.get("deck"))

    if name == "update_image_markdown":
        current = await _current_card()
        image_name = str(arguments.get("image_name", "")).strip()
        if image_name not in current["image_names"]:
            raise ValueError("Das angegebene Bild gehört nicht zur aktuell sichtbaren Anki-Karte.")
        result = await asyncio.to_thread(
            _replace_gemini_markdown,
            image_name,
            str(arguments.get("markdown", "")),
        )
        return {"status": "success", "message": result, "image_name": image_name}

    if name == "show_anki_answer":
        shown = await _invoke("guiShowAnswer", {})
        if not shown:
            raise RuntimeError("Anki konnte die Lösung nicht anzeigen.")
        return {"status": "success", "message": "Die Lösung ist jetzt in Anki sichtbar."}

    if name == "save_anki_ai_note":
        note = str(arguments.get("note", "")).strip()
        if not note:
            raise ValueError("Die KI-Notiz darf nicht leer sein.")
        current = await _current_card()
        await _invoke(
            "updateNoteFields",
            {"note": {"id": current["note_id"], "fields": {"KI-Notiz": note}}},
        )
        return {"status": "success", "message": "KI-Notiz gespeichert.", "ki_note": note}

    if name == "rate_anki_card":
        ease_by_name = {"again": 1, "hard": 2, "good": 3, "easy": 4}
        rating = str(arguments.get("rating", "")).lower()
        if rating not in ease_by_name:
            raise ValueError("Unbekannte Bewertung.")
        previous = await _current_card()
        shown = await _invoke("guiShowAnswer", {})
        if not shown:
            # The answer may already be visible. guiAnswerCard below remains authoritative.
            pass
        answered = await _invoke("guiAnswerCard", {"ease": ease_by_name[rating]})
        if not answered:
            raise RuntimeError("Anki konnte die Karte nicht bewerten.")
        next_card: dict[str, Any] | None = None
        for _ in range(8):
            await asyncio.sleep(0.15)
            try:
                candidate = await _current_card()
            except RuntimeError:
                continue
            next_card = candidate
            if candidate["card_id"] != previous["card_id"]:
                break
        return {
            "status": "success",
            "message": f"Karte als {rating} bewertet. Anki hat die nächste Karte gewählt.",
            "next_card": next_card,
        }

    raise ValueError(f"Unbekanntes Werkzeug: {name}")
