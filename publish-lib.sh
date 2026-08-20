#!/bin/bash
# Gemeinsame Pfadpruefung fuer die Veroeffentlichung.
#
# Wird von `publish_github.sh` und von `Tests/publish-history-filter.sh`
# gesourct, nicht ausgefuehrt. Beide benutzen damit BUCHSTAeBLICH denselben
# Code: Vorher stand die Pipeline zweimal da — einmal im Produktionsskript und
# einmal im Test —, und nur das Suchmuster wurde aus dem Skript herausgelesen.
# Ein Rueckschritt im Produktionscode waere im Test unbemerkt geblieben, weil
# der Test seine eigene, heile Kopie prueft (Review-Fund 2026-08-20).
#
# Alle Funktionen hier arbeiten im aktuellen Arbeitsverzeichnis, also in dem
# Git-Repo, in dem der Aufrufer steht.

# Was niemals oeffentlich werden darf: fremde Musik (Urheberrecht), lokale
# Audioexporte und gebaute Release-Artefakte.
FORBIDDEN_PATTERN='(^audio/|\.sid$|\.mod$|\.wav$|\.aiff?$|\.mp3$|\.flac$|\.dmg$|\.app/|\.zip$|\.tar(\.gz)?$)'

# Liest NUL-getrennte Pfade von der Standardeingabe und gibt die verbotenen
# davon aus, einen je Zeile.
#
# NUL-getrennt ist hier keine Feinheit, sondern der Kern: Git schreibt Pfade
# mit Sonderzeichen sonst C-quotiert, aus `Sammlung/Jörg.sid` wird dann
# `"Sammlung/J\303\266rg.sid"`. Auf so eine Zeile passt weder `\.sid$` (das
# schliessende Anfuehrungszeichen steht im Weg) noch `^audio/` (das oeffnende).
# Eine getrackte Musikdatei mit Umlaut waere damit an der Sperre vorbei
# oeffentlich geworden (Review-Fund 2026-08-20).
#
# Verglichen wird mit der Musterpruefung der Shell selbst statt mit `grep`:
# Ein `grep` je Pfad waere bei tausenden Pfaden aus der Historie spuerbar
# langsam, und ein `grep` ueber den ganzen Strom kann NUL nicht als Trenner.
_filter_forbidden_paths() {
    local path
    # Gross-/Kleinschreibung ignorieren, damit auch `.SID` oder `.Dmg` haengen
    # bleiben — genau das tat vorher das `-i` am grep.
    shopt -s nocasematch
    while IFS= read -r -d '' path; do
        if [[ "$path" =~ $FORBIDDEN_PATTERN ]]; then
            printf '%s\n' "$path"
        fi
    done
    shopt -u nocasematch
}

# Verbotene Pfade im AKTUELLEN Stand (alles, was Git gerade verfolgt).
forbidden_paths_now() {
    git ls-files -z | _filter_forbidden_paths | sort -u
}

# Verbotene Pfade in der GESAMTEN erreichbaren Historie.
#
# Das ist der Punkt, den ein Blick auf den aktuellen Baum nicht abdeckt:
# `git push` uebertraegt die ganze Historie. Eine einmal committete und spaeter
# geloeschte Musikdatei steckt weiterhin in einem alten Commit und waere nach
# dem Push oeffentlich abrufbar, waehrend der aktuelle Stand voellig sauber
# aussieht.
#
# Warum jeder Commit einzeln statt des viel billigeren
# `git rev-list --objects --all`: Diese Ausgabe nennt zu jedem Objekt nur EINEN
# Fundort. Lag derselbe Inhalt einmal als `README.md` und einmal als
# `Sammlung/Kopie.sid` im Baum, steht dort unter Umstaenden nur `README.md` —
# der verbotene Name kommt in der Ausgabe dann gar nicht vor
# (Review-Fund 2026-08-20). `git ls-tree -r` je Commit listet dagegen
# verlustfrei jeden Pfad jedes Standes.
forbidden_paths_ever() {
    local commit
    while read -r commit; do
        git ls-tree -r -z --name-only "$commit"
    done < <(git rev-list --all) | _filter_forbidden_paths | sort -u
}
