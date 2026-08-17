#!/usr/bin/env bash
# Deterministische Fakten für den PR-Documenter (Phase 7) und den Reviewer (Phase 5).
#
# WARUM: Bot-Erkennung, Conventional-Commits-Titelprüfung und Typ-/Scope-Vorschläge
# sind reine Regel-Logik — sie gehören NICHT ins LLM (empirische Folge des bisherigen
# Prompt-only-Ansatzes: Titel wie "perf/#692: ..." und "feat/issue-671-..." blieben
# unnormalisiert hängen, obwohl der Documenter lief). Dieses Skript ist die EINE
# Quelle der Titel-Regel; pr-doc-render.sh validiert LLM-Titel-Vorschläge gegen
# dieselbe Struktur (Regex via grep -E, Länge via bash-String-Ops — bewusst KEIN
# `grep -P`/`\K`, das ist GNU-only und auf macOS-BSD grep falsch).
#
# Wie check-phase-label.sh / pr-for-issue.sh: lokal gegen echte Tickets ausführbar:
#   bash .github/scripts/pr-doc-facts.sh --repo deleonio/priority-pilot --pr 693
#   bash .github/scripts/pr-doc-facts.sh --repo o/r --pr 42 --mode title-only
#
# Ausgabe (stdout, key=value — der Workflow reicht nach $GITHUB_OUTPUT durch):
#   facts_ok=true|false     gh-Abfrage erfolgreich? false => Aufrufer mit Fallback weiterarbeiten
#   title_ok=true|false     Titel erfüllt Conventional Commits (siehe CC_REGEX unten)
#   suggested_type=...      Pfad-Heuristik: ci|docs|test|build|feat|chore
#   suggested_scope=...     häufigstes Top-Level-Verzeichnis (frontend|server|client), sonst leer
#   bot_skip=true|false     Bot-Autor UND nur Dependency-/Renovate-Pfade
#   already_ignored=...     PR trägt bereits release:ignore
#   body_len=N              Länge des aktuellen PR-Bodys (Body-Policy)
#   linked_issues=1,2,...   Closing-Issue-Nummern (kommasepariert, evtl. leer)
#
# --mode title-only: nur facts_ok/title_ok/suggested_* (Phase 5 braucht keine Body-Fakten).

set -uo pipefail

REPO=""
PR=""
MODE="full"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --pr) PR="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$REPO" ] || { echo "pr-doc-facts: --repo required" >&2; exit 2; }
[ -n "$PR" ] || { echo "pr-doc-facts: --pr required" >&2; exit 2; }

# Conventional-Commits-Regel: type(scope)!: subject — Subject beginnt klein (Sprachregel:
# Titel englisch), max. 60 Zeichen Subject / 72 gesamt (Länge separat in bash geprüft).
# LC_ALL=C: deterministisches Byte-Matching, unabhängig von der Runner-Locale.
CC_REGEX='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9._/-]+\))?!?: [a-z0-9]'

# Ein EINZIGER gh-Abruf für alle Fakten. Fail-open (facts_ok=false): ein transienter
# gh-Ausfall darf den Documenter nicht still kippen — der Prompt enthält Prosa-Fallbacks.
DATA="$(gh pr view "$PR" --repo "$REPO" \
  --json title,body,author,files,labels,closingIssuesReferences 2>/dev/null)"
if [ -z "$DATA" ]; then
  echo "facts_ok=false"
  exit 0
fi

title_ok() {
  local t="$1"
  [ "${#t}" -le 72 ] || return 1
  printf '%s' "$t" | LC_ALL=C grep -Eq "$CC_REGEX" || return 1
  # Subject-Zeichenlimit separat (bash zählt Zeichen, grep Bytes — bei Umlauten ungleich).
  local subject="${t#*: }"
  [ "${#subject}" -le 60 ]
}

# Pfade als bash-Array lesen (jq -r => eine Zeile je Datei). Kein `mapfile`:
# bash 4+, der lokale Lauf auf macOS-Default-bash 3.2 würde abstürzen.
paths=()
while IFS= read -r p; do
  paths+=("$p")
done < <(printf '%s' "$DATA" | jq -r '.files[].path' 2>/dev/null || true)

all_paths_match() {
  # "alle Pfade matchen Muster $1" — leere Dateiliste zaehlt als NICHT matchend (kein Diff = kein PR).
  [ "${#paths[@]}" -gt 0 ] || return 1
  local p
  for p in "${paths[@]}"; do
    printf '%s' "$p" | LC_ALL=C grep -Eq "$1" || return 1
  done
  return 0
}

any_path_match() {
  local p
  for p in ${paths[@]+"${paths[@]}"}; do
    printf '%s' "$p" | LC_ALL=C grep -Eq "$1" && return 0
  done
  return 1
}

suggested_type() {
  # Schmale Kategorien nur bei ALL-match (reiner Workflow-/Build-/Test-/Doku-PR); gemischte
  # PRs (typisch: Code + Spec-Artefakt docs/spec/*.md + Test) fallen auf "feat" — der
  # App-Code ist der Substanz nach die Änderung, nicht das mitgeführte Artefakt.
  if all_paths_match '^\.github/'; then echo "ci"
  elif all_paths_match '^(package\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml|.*\.config\.[cm]?[jt]s|tsconfig.*|\.nvmrc)$'; then echo "build"
  elif all_paths_match '\.(spec|test)\.tsx?$'; then echo "test"
  elif all_paths_match '^docs/|\.md$'; then echo "docs"
  elif any_path_match '^(frontend|server|client)/.*\.(css|tsx?|jsx?|vue|svelte)$'; then echo "feat"
  else echo "chore"
  fi
}

suggested_scope() {
  # Häufigstes Top-Level-Verzeichnis, nur aus den App-Workspaces (sonst leer — ein
  # Scope wie "root" oder ".github" hilft keinem Titel).
  printf '%s\n' "${paths[@]+"${paths[@]}"}" | awk -F/ '$1 ~ /^(frontend|server|client)$/ {print $1}' \
    | sort | uniq -c | sort -rn | awk 'NR==1 {print $2}'
}

TITLE="$(printf '%s' "$DATA" | jq -r '.title')"
if title_ok "$TITLE"; then TITLE_OK="true"; else TITLE_OK="false"; fi
echo "title_ok=$TITLE_OK"
echo "suggested_type=$(suggested_type)"
echo "suggested_scope=$(suggested_scope)"

[ "$MODE" = "title-only" ] && { echo "facts_ok=true"; exit 0; }

# Bot-Kurzschluss: Autor ist Renovate/Dependabot/Actions-Bot UND der Diff berührt nur
# Dependency-/Renovate-Dateien. Nur der Autor reicht nicht — der App-Bot author auch
# echte Pipeline-PRs.
AUTHOR="$(printf '%s' "$DATA" | jq -r '.author.login // ""')"
if printf '%s' "$AUTHOR" | LC_ALL=C grep -Eq '^(renovate|dependabot|github-actions)\[bot\]$' \
  && all_paths_match '^(pnpm-lock\.yaml|package\.json|renovate\.json5|\.github/renovate.*)$'; then
  echo "bot_skip=true"
else
  echo "bot_skip=false"
fi

if printf '%s' "$DATA" | jq -e 'any(.labels[]; .name == "release:ignore")' >/dev/null; then
  echo "already_ignored=true"
else
  echo "already_ignored=false"
fi

echo "body_len=$(printf '%s' "$DATA" | jq -r '.body | length')"
echo "linked_issues=$(printf '%s' "$DATA" | jq -r '[.closingIssuesReferences[].number] | map(tostring) | join(",")')"

echo "facts_ok=true"
