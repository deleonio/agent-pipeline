#!/usr/bin/env bash
# Prüft, ob der Trigger einer Pipeline-Phase zur LAUFZEIT noch gültig ist.
#
# WARUM: Die Phasen-Workflows (01–07) serialisieren global über eine statische
# concurrency-Gruppe pro Phase — Läufe stapeln sich (FIFO). Zwischen Trigger und
# Job-Start können Minuten liegen, in denen ein anderer Lauf das Trigger-Label
# längst konsumiert hat. Das `job-if` sieht nur den Event-Payload vom TRIGGER-
# Zeitpunkt und würde die Phase falsch wiederholen. Dieses Skript fragt den
# IST-Zustand ab; passt er nicht zum Soll der Phase, endet der Job ohne Fehler.
#
# Bash (kein .ts): reine gh-/jq-Wrapper-Logik, aufgerufen aus einer Composite-
# Action — analog pr-for-issue.sh. Ausgelagert statt inline in action.yml, damit
# die Logik LOKAL gegen echte Tickets ausführbar (und damit belegbar) bleibt:
#   bash .github/scripts/check-phase-label.sh --repo o/r --phase spec --ticket 42
#
# Soll-Zustand je Phase (die Tabelle ist die einzige Wahrheit — Workflows
# übergeben nur den Phasen-Namen):
#
#   Phase       Objekt  Zustand        erforderlich                         abwesend
#   -----------------------------------------------------------------------------------
#   analyse     Issue   offen          —                                    Trigger-Label
#                                                                     (Default ai:analyzed)
#   ux          Issue   offen          ai:analyzed                          ux:ready
#   spec        Issue   offen          ai:spec-ready + ai:analyzed +        —
#                                   ux:ready
#   implement   Issue   offen          ai:ready + ai:analyzed +              —
#                                   ux:ready
#   review      PR      offen, kein    ai:needs-review                      —
#                       Draft
#   fixup       PR      offen, kein    ai:needs-changes                     —
#                       Draft
#   documenter  PR      gemergt        —                                    ai:documented
#
# Usage:
#   bash check-phase-label.sh --repo <owner/repo> --phase <name> --ticket <N> \
#                             [--trigger-label <label>]
#   --trigger-label: nur für `analyse` relevant (github.event.label.name). Beim
#                    Re-Triage muss GENAU das entfernte Label abwesend bleiben
#                    (ai:analyzed ODER ai:to-big-issue); leer => ai:analyzed.
#
# Ausgabe (stdout, key=value — die Action reicht sie nach GITHUB_OUTPUT durch):
#   proceed=true|false
#   reason=<Klartext, nur bei proceed=false>

set -uo pipefail

REPO=""
PHASE=""
TICKET=""
TRIGGER_LABEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --phase) PHASE="$2"; shift 2 ;;
    --ticket) TICKET="$2"; shift 2 ;;
    --trigger-label) TRIGGER_LABEL="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$REPO" ] || { echo "check-phase-label: --repo required" >&2; exit 2; }
[ -n "$PHASE" ] || { echo "check-phase-label: --phase required" >&2; exit 2; }
[ -n "$TICKET" ] || { echo "check-phase-label: --ticket required" >&2; exit 2; }

# Soll-Werte aus dem Phasen-Namen auflösen. Eine unbekannte Phase ist ein HARTER
# Fehler (exit 2), kein Fail-open und kein Skip: ein Tippfehler im Workflow
# ("implment") würde sonst entweder das Gate still aushebeln oder die Phase
# dauerhaft stilllegen — beides fiele erst im Produktivbetrieb auf.
#
# REQUIRED/ABSENT sind ARRAYS, keine Leerzeichen-Strings: Label-Namen dürfen
# Leerzeichen und Glob-Zeichen enthalten ("good first issue", "*"). Eine
# ungequotete Wortzerlegung hätte den Abwesenheits-Check umgehbar gemacht, weil
# `for l in $ABSENT` das Muster gegen das CWD (auf dem Runner das Repo-Root)
# expandiert.
KIND=""        # issue | pr
WANT_STATE=""  # open | merged
NO_DRAFT="false"
FAIL_MODE="open" # Verhalten bei nicht erreichbarer API (open = Phase läuft trotzdem)
REQUIRED=()
ABSENT=()
case "$PHASE" in
  analyse)
    KIND="issue"; WANT_STATE="open"
    # Erst-Triage (opened): ai:analyzed darf nicht da sein. Re-Triage (unlabeled):
    # genau das entfernte Label muss abwesend bleiben — sonst hat ein anderer Lauf
    # den Trigger bereits konsumiert.
    ABSENT=("${TRIGGER_LABEL:-ai:analyzed}")
    ;;
  spec)
    KIND="issue"; WANT_STATE="open"; REQUIRED=("ai:spec-ready" "ai:analyzed" "ux:ready") ;;
  ux)
    KIND="issue"; WANT_STATE="open"; REQUIRED=("ai:analyzed"); ABSENT=("ux:ready") ;;
  implement)
    KIND="issue"; WANT_STATE="open"; REQUIRED=("ai:ready" "ai:analyzed" "ux:ready") ;;
  review)
    KIND="pr"; WANT_STATE="open"; NO_DRAFT="true"; REQUIRED=("ai:needs-review") ;;
  fixup)
    KIND="pr"; WANT_STATE="open"; NO_DRAFT="true"; REQUIRED=("ai:needs-changes") ;;
  documenter)
    # FAIL-CLOSED (Ausnahme): Der Pre-Check ist die EINZIGE Idempotenz-Invariante
    # des Documenters — im Job prüft nichts deterministisch auf ai:documented.
    # Ein verlorener Lauf ist per workflow_dispatch nachholbar; ein doppelter
    # überschreibt Titel/Beschreibung und postet einen zweiten Release-Kommentar,
    # was nicht rückgängig zu machen ist. Also im Zweifel NICHT laufen.
    KIND="pr"; WANT_STATE="merged"; ABSENT=("ai:documented"); FAIL_MODE="closed" ;;
  *)
    echo "check-phase-label: unbekannte Phase '$PHASE' (erlaubt: analyse spec ux implement review fixup documenter)" >&2
    exit 2
    ;;
esac

# IST-Zustand in EINEM API-Aufruf holen. Fail-open bei Fehler: ein transienter
# gh-Ausfall darf eine Phase nicht still verschlucken — lieber einmal zu viel
# laufen (die Phasen sind idempotent und haben eigene Artefakt-Guards) als eine
# Freigabe zu verlieren.
if [ "$KIND" = "pr" ]; then
  DATA="$(gh pr view "$TICKET" --repo "$REPO" --json state,isDraft,labels 2>/dev/null)"
else
  DATA="$(gh issue view "$TICKET" --repo "$REPO" --json state,labels 2>/dev/null)"
fi
if [ -z "$DATA" ]; then
  if [ "$FAIL_MODE" = "closed" ]; then
    echo "proceed=false"
    echo "reason=API-Abfrage fehlgeschlagen — fail-closed (ein Doppel-Lauf wäre nicht rückgängig zu machen)"
  else
    echo "proceed=true"
    echo "check-phase-label: API-Abfrage fehlgeschlagen — fail-open" >&2
  fi
  exit 0
fi

# gh liefert das GraphQL-Enum in GROSSBUCHSTABEN ("OPEN"/"CLOSED"/"MERGED").
# Klein normalisieren, sonst schlägt jeder Vergleich fehl und die Phase wird
# dauerhaft übersprungen (genau dieser Fehler legte alle Prechecks still).
STATE="$(printf '%s' "$DATA" | jq -r '.state' | tr '[:upper:]' '[:lower:]')"

# reason wird von der Action nach $GITHUB_OUTPUT geschrieben und enthält
# Label-Namen aus dem Event. Zeilenumbrüche/CR hier strippen, damit der Wert
# garantiert einzeilig bleibt und keine weiteren Output-Keys injizierbar sind.
fail() {
  echo "proceed=false"
  printf 'reason=%s\n' "$(printf '%s' "$1" | tr -d '\n\r')"
  exit 0
}

case "$WANT_STATE" in
  open)
    [ "$STATE" = "open" ] || fail "Ticket #${TICKET} ist nicht mehr offen (state=${STATE})" ;;
  merged)
    # "merged" ist ein eigener state-Wert; ein geschlossener-ohne-Merge-PR ist "closed".
    [ "$STATE" = "merged" ] || fail "PR #${TICKET} ist nicht (mehr) gemergt (state=${STATE})" ;;
esac

if [ "$NO_DRAFT" = "true" ]; then
  DRAFT="$(printf '%s' "$DATA" | jq -r '.isDraft')"
  [ "$DRAFT" != "true" ] || fail "PR #${TICKET} ist inzwischen Draft"
fi

# ${ARR[@]+"${ARR[@]}"} statt "${ARR[@]}": unter `set -u` bricht die kurze Form
# bei LEEREM Array in bash 3.2 (macOS-Default) mit "unbound variable" ab.
for label in ${REQUIRED[@]+"${REQUIRED[@]}"}; do
  has="$(printf '%s' "$DATA" | jq -r --arg l "$label" 'any(.labels[]; .name == $l)')"
  [ "$has" = "true" ] || fail "Label '${label}' fehlt inzwischen — Trigger ist konsumiert"
done

for label in ${ABSENT[@]+"${ABSENT[@]}"}; do
  has="$(printf '%s' "$DATA" | jq -r --arg l "$label" 'any(.labels[]; .name == $l)')"
  [ "$has" != "true" ] || fail "Label '${label}' wurde inzwischen (erneut) gesetzt — Trigger ist konsumiert"
done

echo "proceed=true"
