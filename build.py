#!/usr/bin/env python3
"""
build.py — bündelt alle Quellen zu einer einzigen, minifizierten vicious-sid-player.html.

Quelldateien:
    sidplayer.js                SID-Parser + Client-Wrapper (ES-Modul)
    sid-player-worklet.js       AudioWorklet-CPU- & SID-Emulator
    src/styles.css              UI-Styles
    src/body.html               Body-Markup
    src/app.js                  App-Logik (DOM-Wiring, Drag&Drop, …)

"""

from __future__ import annotations

import base64
import re
import sys
from pathlib import Path

HERE = Path(__file__).parent
SRC_DIR = HERE / 'src'
AUDIO_DIR = HERE / 'audio'


# ─────────────────────────────────────────────────────────────────────────────
# Minifizierer
# ─────────────────────────────────────────────────────────────────────────────

def strip_js_comments(src: str) -> str:
    """
    Entfernt JavaScript-Kommentare, ohne Strings oder Template-Literale
    zu zerschießen.
    """
    out = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ''

        # String-Literale durchreichen (mit Escapes).
        if c in ('"', "'", '`'):
            quote = c
            out.append(c)
            i += 1
            while i < n:
                ch = src[i]
                if ch == '\\' and i + 1 < n:
                    out.append(ch)
                    out.append(src[i + 1])
                    i += 2
                    continue
                out.append(ch)
                i += 1
                if ch == quote:
                    break
            continue

        # Zeilenkommentar: alles bis zum Newline schlucken (Newline behalten).
        if c == '/' and nxt == '/':
            i += 2
            while i < n and src[i] != '\n':
                i += 1
            continue

        # Block-Kommentar: alles bis zum nächsten "*/" schlucken.
        if c == '/' and nxt == '*':
            i += 2
            while i < n - 1 and not (src[i] == '*' and src[i + 1] == '/'):
                i += 1
            i += 2  # über "*/" hinwegspringen
            continue

        out.append(c)
        i += 1
    return ''.join(out)


def collapse_js_whitespace(src: str) -> str:
    """
    Kollabiert Whitespace im JavaScript, ohne Strings zu berühren.
    """
    out = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]

        # Strings durchreichen.
        if c in ('"', "'", '`'):
            quote = c
            out.append(c)
            i += 1
            while i < n:
                ch = src[i]
                if ch == '\\' and i + 1 < n:
                    out.append(ch)
                    out.append(src[i + 1])
                    i += 2
                    continue
                out.append(ch)
                i += 1
                if ch == quote:
                    break
            continue

        # Whitespace-Block zusammenfassen.
        if c.isspace():
            had_newline = False
            while i < n and src[i].isspace():
                if src[i] == '\n':
                    had_newline = True
                i += 1
            out.append('\n' if had_newline else ' ')
            continue

        out.append(c)
        i += 1
    return ''.join(out)


def tighten_js_punctuation(src: str) -> str:
    """
    Entfernt unnötige Spaces direkt vor/nach Satzzeichen.
    """
    punct = r'[{}()\[\];,:?=<>+\-*/%&|^!~]'
    src = re.sub(rf' *({punct}) *', r'\1', src)
    src = re.sub(r'\n{2,}', '\n', src)
    src = re.sub(r'[ \t]+\n', '\n', src)
    src = re.sub(r'\n[ \t]+', '\n', src)
    return src.strip()


def minify_js(src: str) -> str:
    """JS minifizieren — Kommentare raus, Whitespace straffen."""
    src = strip_js_comments(src)
    src = collapse_js_whitespace(src)
    src = tighten_js_punctuation(src)
    return src


def minify_css(src: str) -> str:
    """CSS minifizieren."""
    src = re.sub(r'/\*.*?\*/', '', src, flags=re.DOTALL)
    src = re.sub(r'\s*([{}:;,>])\s*', r'\1', src)
    src = src.replace(';}', '}')
    src = re.sub(r'\s+', ' ', src)
    return src.strip()


def minify_html(src: str) -> str:
    """HTML minifizieren."""
    src = re.sub(r'<!--.*?-->', '', src, flags=re.DOTALL)
    src = re.sub(r'>\s+<', '><', src)
    src = re.sub(r'\s+', ' ', src)
    return src.strip()


# ─────────────────────────────────────────────────────────────────────────────
# Bündelung
# ─────────────────────────────────────────────────────────────────────────────

def strip_module_keywords(src: str) -> str:
    """
    Entfernt ES-Modul-Keywords aus sidplayer.js, damit das Skript inline
    in einem <script>-Tag funktioniert.
    """
    return (src
            .replace('export class', 'class')
            .replace('export async function', 'async function')
            .replace('export function', 'function'))


def get_base64_of_file(filepath: Path) -> str:
    """Liest eine Datei ein und liefert deren Inhalt als Base64-String."""
    if not filepath.exists():
        print(f"Warnung: {filepath} nicht gefunden. Inlining leer.")
        return ""
    data = filepath.read_bytes()
    return base64.b64encode(data).decode('utf-8')


def build(minify: bool = True) -> Path:
    """Baut die finale sidplayer.html."""
    worklet_src = (HERE / 'sid-player-worklet.js').read_text()
    sidplayer_src = (HERE / 'sidplayer.js').read_text()
    css_src = (SRC_DIR / 'styles.css').read_text()
    body_src = (SRC_DIR / 'body.html').read_text()
    app_src = (SRC_DIR / 'app.js').read_text()

    # Version einpflegen
    version = (HERE / 'VERSION').read_text().strip()
    body_src = body_src.replace('{{VERSION}}', version)

    sidplayer_src = strip_module_keywords(sidplayer_src)

    if minify:
        worklet_src = minify_js(worklet_src)
        sidplayer_src = minify_js(sidplayer_src)
        app_src = minify_js(app_src)
        css_src = minify_css(css_src)
        body_src = minify_html(body_src)

    html = (
        '<!doctype html>'
        '<html lang="de">'
        '<head>'
        '<meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        "<title>Vicious SID Player</title>"
        f'<style>{css_src}</style>'
        '</head>'
        '<body>'
        f'{body_src}'
        '<script>'
        f'const WORKLET_SOURCE={worklet_src!r};'
        "const WORKLET_BLOB_URL=URL.createObjectURL(new Blob([WORKLET_SOURCE],{type:'application/javascript'}));"
        f'{sidplayer_src}\n'
        f'{app_src}'
        '</script>'
        '</body>'
        '</html>'
    )

    out = HERE / 'vicious-sid-player.html'
    out.write_text(html)
    return out


def main(argv: list[str]) -> int:
    minify = '--no-min' not in argv and '--no-minify' not in argv
    out = build(minify=minify)
    size = out.stat().st_size
    mode = 'minifiziert' if minify else 'unminifiziert'
    print(f'Geschrieben: {out} ({size:,} Bytes, {mode})')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
