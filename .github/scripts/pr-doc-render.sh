#!/usr/bin/env bash
# Render-Schritt des PR-Documenters: übernimmt ALLE Schreibzugriffe auf den PR.
#
# WARUM: Kommentar-Format, Body-Policy, Label-Reihenfolge und Titel-Umbenennung sind
# Struktur-Entscheidungen — im LLM-Prompt waren sie Prosa und drifteten (empirisch:
# "### Release Note (feat, dx)" vs. "**Release Note (fixed/ci):**" vs. drittes Format
# auf #698/#690/#684). Dieses Skript konsumiert das LLM-Ergebnis (/tmp/doc.json, s.
# .github/prompts/documenter.md), validiert es hart und rendert daraus:
#   1. Titel   — nur wenn doc.title valid ist (gleiche CC-Regex wie pr-doc-facts.sh)
#   2. Body    — eigene Sektion zwischen <!-- ai-documenter-body -->-Markern, REST DES
#                BODYS BLEIBT UNANGETASTET (Implement-/Human-Beschreibung bleibt stehen)
#   3. Kommentar — GENAU EINER (vorhandener <!-- ai-documenter -->-Kommentar wird per
#                PATCH aktualisiert statt dupliziert)
#   4. Labels  — ai:documented ZULETZT (Idempotenz-Invariante des fail-closed-Prechecks),
#                davor das release:*-Mapping; vorhandene release:* bleiben unangetastet
#
# Ungültiges/fehlendes doc.json => Fallback: Minimal-Kommentar + ai:documented +
# release:engineering + ::warning, Exit 0. Bewusst KEIN harter Fehler: der Precheck von
# Phase 7 ist fail-closed auf ai:documented — ein roter Job wäre nicht re-runbar und
# damit eine Sackgasse. Nur wenn ai:documented selbst nicht setzbar ist: Exit 1 (der
# Precheck lässt dann einen Re-Run zu).
#
# Lokal testbar (kein Schreiben):
#   bash .github/scripts/pr-doc-render.sh --repo o/r --pr 693 --doc /tmp/doc.json --dry-run

set -uo pipefail

REPO=""
PR=""
DOC="/tmp/doc.json"
DRY_RUN="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --pr) PR="$2"; shift 2 ;;
    --doc) DOC="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    *) shift ;;
  esac
done
[ -n "$REPO" ] || { echo "pr-doc-render: --repo required" >&2; exit 2; }
[ -n "$PR" ] || { echo "pr-doc-render: --pr required" >&2; exit 2; }

# Identische Conventional-Commits-Regex wie in pr-doc-facts.sh (Doku-Pflicht dort). Wer
# sie ändert, ändert sie an BEIDEN Stellen — der Renderer ist die zweite Instanz gegen
# LLM-Titel-Vorschläge, die die Regel verletzen.
CC_REGEX='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9._/-]+\))?!?: [a-z0-9]'

title_valid() {
  local t="$1"
  [ -n "$t" ] || return 1
  [ "${#t}" -le 72 ] || return 1
  printf '%s' "$t" | LC_ALL=C grep -Eq "$CC_REGEX" || return 1
  local subject="${t#*: }"
  [ "${#subject}" -le 60 ]
}

# gh-Aufrufe mit Kurz-Retry: transiente API-Löcher dürfen keine halbe Dokumentation
# hinterlassen (nach ai:documented gibt es keinen Re-Run mehr).
gh_retry() {
  local n=1
  until "$@"; do
    if [ "$n" -ge 3 ]; then return 1; fi
    sleep "$n"
    n=$((n + 1))
  done
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# 0) doc.json laden + validieren (ungültig => Fallback-Pfad unten)
# ---------------------------------------------------------------------------
DOC_OK="false"
CLASSIFICATION=""
NEW_TITLE=""
if [ -s "$DOC" ]; then
  if jq -e '
    .classification as $c
    | (["breaking","new","improved","fixed","internal"] | index($c)) != null
    and (.summary_en | type == "string" and length > 0)
    and (.summary_de | type == "string" and length > 0)
    and (.release_note_en | type == "string" and length > 0)
  ' "$DOC" >/dev/null 2>&1; then
    DOC_OK="true"
    CLASSIFICATION="$(jq -r '.classification' "$DOC")"
    NEW_TITLE="$(jq -r '.title // ""' "$DOC")"
    if [ -n "$NEW_TITLE" ] && ! title_valid "$NEW_TITLE"; then
      echo "⚠️ doc.title ungültig gegen Conventional-Commits-Regel — lasse Titel unverändert: $NEW_TITLE"
      NEW_TITLE=""
    fi
  else
    echo "::warning title=doc.json ungültig::Validierung fehlgeschlagen (Schema siehe .github/prompts/documenter.md) — Fallback-Dokumentation."
  fi
else
  echo "::warning title=doc.json fehlt::Claude hat keine Ausgabedatei geschrieben — Fallback-Dokumentation."
fi

# Aktuelle PR-Daten (für Titel-Vergleich, Body-Splice, Label-Zustand).
CUR="$(gh_retry gh pr view "$PR" --repo "$REPO" --json title,body,labels 2>/dev/null || true)"
if [ -z "$CUR" ]; then
  echo "::error title=PR nicht lesbar::gh pr view #$PR schlug nach 3 Versuchen fehl — nichts dokumentiert, ai:documented NICHT gesetzt (Re-Run möglich)."
  exit 1
fi
CUR_TITLE="$(printf '%s' "$CUR" | jq -r '.title')"
CUR_BODY="$(printf '%s' "$CUR" | jq -r '.body // ""')"
HAS_RELEASE="$(printf '%s' "$CUR" | jq -r 'any(.labels[]; (.name | startswith("release:")))')"

release_label() {
  case "$1" in
    breaking) echo "release:breaking-change" ;;
    new) echo "release:feature" ;;
    improved) echo "release:improvement" ;;
    fixed) echo "release:fix" ;;
    *) echo "release:engineering" ;;
  esac
}

type_line() {
  case "$1" in
    breaking) echo "💥 Breaking change" ;;
    new) echo "✨ New feature" ;;
    improved) echo "🔼 Improvement" ;;
    fixed) echo "🐛 Bug fix" ;;
    *) echo "🔧 Internal (no release note needed)" ;;
  esac
}

# ---------------------------------------------------------------------------
# Fallback: minimale Dokumentation, Job bleibt grün (siehe Kopf-Kommentar).
# ---------------------------------------------------------------------------
if [ "$DOC_OK" != "true" ]; then
  cat > "$WORK/comment.md" << 'EOF'
<!-- ai-documenter -->
🤖 **Auto-documentation incomplete** — the AI analysis result was missing or invalid, so no release note was generated. The PR is marked `ai:documented` to avoid a duplicate run; please review and document manually if this change needs a release note.

---
*Generated by PR Documenter (fallback path)*
EOF
  if [ "$DRY_RUN" = "true" ]; then
    echo "[dry-run] Kommentar:"; cat "$WORK/comment.md"
    echo "[dry-run] Labels: ai:documented, release:engineering"
  else
    if ! gh_retry gh pr comment "$PR" --repo "$REPO" --body-file "$WORK/comment.md"; then
      echo "::warning title=Fallback-Kommentar fehlgeschlagen::Konnte nicht gepostet werden."
    fi
    gh_retry gh pr edit "$PR" --repo "$REPO" --add-label release:engineering || \
      echo "::warning title=release:engineering fehlgeschlagen::Best-effort."
    gh_retry gh pr edit "$PR" --repo "$REPO" --add-label ai:documented || {
      echo "::error title=ai:documented nicht setzbar::Re-Run ist möglich (Precheck greift nicht)."
      exit 1
    }
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# 1) Titel
# ---------------------------------------------------------------------------
if [ -n "$NEW_TITLE" ] && [ "$NEW_TITLE" != "$CUR_TITLE" ]; then
  if [ "$DRY_RUN" = "true" ]; then
    echo "[dry-run] Titel: '$CUR_TITLE' -> '$NEW_TITLE'"
  else
    if gh_retry gh pr edit "$PR" --repo "$REPO" --title "$NEW_TITLE"; then
      echo "📝 Titel umbenannt: '$CUR_TITLE' -> '$NEW_TITLE'"
    else
      echo "::warning title=Titel-Rename fehlgeschlagen::Best-effort, Body/Kommentar laufen weiter."
      NEW_TITLE=""
    fi
  fi
else
  NEW_TITLE=""
fi

# ---------------------------------------------------------------------------
# 2) Body-Sektion (Marker-Splice; bestehender Body bleibt unangetastet)
# ---------------------------------------------------------------------------
jq -r '.summary_en' "$DOC" > "$WORK/summary_en.txt"
jq -r '.summary_de' "$DOC" > "$WORK/summary_de.txt"
jq -r '.release_note_en' "$DOC" > "$WORK/release_note_en.txt"
jq -r '.migration_en // ""' "$DOC" > "$WORK/migration_en.txt"
jq -r '.title_reason // ""' "$DOC" > "$WORK/title_reason.txt"

{
  echo '<!-- ai-documenter-body -->'
  echo "## What changed?"
  echo
  cat "$WORK/summary_en.txt"
  echo
  echo "## Linked issues"
  echo
  if jq -e '.issues | type == "array" and length > 0' "$DOC" >/dev/null; then
    jq -r '.issues[] | "- \(.ref) — \(.note // "")"' "$DOC"
  else
    echo "No linked issues."
  fi
  echo
  echo "## Type of change"
  echo
  echo "- $(type_line "$CLASSIFICATION")"
  echo
  echo '<details>'
  echo '<summary>🇩🇪 Deutsche Zusammenfassung</summary>'
  echo
  echo "### Was wurde geändert?"
  echo
  cat "$WORK/summary_de.txt"
  echo
  echo "### Verknüpfte Tickets"
  echo
  if jq -e '.issues | type == "array" and length > 0' "$DOC" >/dev/null; then
    jq -r '.issues[] | "- \(.ref) — \(.note // "")"' "$DOC"
  else
    echo "Keine verknüpften Tickets."
  fi
  echo
  echo "### Geänderte Dateien"
  echo
  if jq -e '.files | type == "array" and length > 0' "$DOC" >/dev/null; then
    jq -r '.files[] | "- `\(.path)` — \(.note_de // "")"' "$DOC"
  else
    echo "Keine Dateiliste übermittelt."
  fi
  echo
  echo '</details>'
  echo '<!-- /ai-documenter-body -->'
} > "$WORK/section.md"

# Splice: existierende Marker-Sektion ersetzen, sonst hinten anhängen. Die Sektion
# kommt aus einer Datei (awk-getline), nicht aus -v — Multiline-Backslash-Escapes
# würden sonst verfälscht.
printf '%s\n' "$CUR_BODY" > "$WORK/body.txt"
awk -v secfile="$WORK/section.md" '
  /^<!-- ai-documenter-body -->$/ { insec = 1; printed = 1; while ((getline line < secfile) > 0) print line; close(secfile); next }
  /^<!-- \/ai-documenter-body -->$/ { insec = 0; next }
  insec { next }
  { print }
  END {
    if (!printed) {
      if (NR > 0) print ""
      while ((getline line < secfile) > 0) print line
      close(secfile)
    }
  }
' "$WORK/body.txt" > "$WORK/body-new.txt"

if [ "$DRY_RUN" = "true" ]; then
  echo "[dry-run] Neuer PR-Body:"; cat "$WORK/body-new.txt"
else
  if gh_retry gh pr edit "$PR" --repo "$REPO" --body-file "$WORK/body-new.txt"; then
    echo "📄 PR-Beschreibung: Documenter-Sektion eingepflegt (Marker-Splice)."
  else
    echo "::warning title=Body-Update fehlgeschlagen::Best-effort, Kommentar/Labels laufen weiter."
  fi
fi

# ---------------------------------------------------------------------------
# 3) Release-Note-Kommentar (genau einer, PATCH statt Duplikat)
# ---------------------------------------------------------------------------
FINAL_TITLE="$CUR_TITLE"
[ -n "$NEW_TITLE" ] && FINAL_TITLE="$NEW_TITLE"
SCOPE="$(printf '%s' "$FINAL_TITLE" | sed -nE 's/^[a-z]+\(([^)]+)\).*/\1/p')"

{
  echo '<!-- ai-documenter -->'
  if [ "$CLASSIFICATION" = "internal" ]; then
    echo "🔧 **Internal change — no release note required.**"
    echo
    cat "$WORK/release_note_en.txt"
  else
    echo "## 📝 Release note"
    echo
    echo "**$(type_line "$CLASSIFICATION")** — \`${SCOPE:-repository}\`"
    echo
    cat "$WORK/release_note_en.txt"
  fi
  echo
  if [ "$(cat "$WORK/migration_en.txt")" != "" ]; then
    echo "> ⚠️ **Migration required:** $(cat "$WORK/migration_en.txt")"
    echo
  fi
  if [ -n "$NEW_TITLE" ]; then
    echo "> 📝 **Title corrected:** \`$CUR_TITLE\` → \`$NEW_TITLE\` — $(cat "$WORK/title_reason.txt")"
    echo
  fi
  echo "---"
  echo "*Generated by PR Documenter — please review before release*"
} > "$WORK/comment.md"

if [ "$DRY_RUN" = "true" ]; then
  echo "[dry-run] Kommentar:"; cat "$WORK/comment.md"
  echo "[dry-run] Labels: ai:documented$( [ "$HAS_RELEASE" = "true" ] || echo ", $(release_label "$CLASSIFICATION")" )"
else
  existing_id="$(gh_retry gh api "repos/$REPO/issues/$PR/comments?per_page=100" \
    --paginate --jq '.[] | select(.body | startswith("<!-- ai-documenter -->")) | .id' 2>/dev/null \
    | sed -n '1p' || true)"
  if [ -n "$existing_id" ]; then
    if gh_retry gh api --method PATCH "repos/$REPO/issues/comments/$existing_id" -F "body=@$WORK/comment.md"; then
      echo "💬 Documenter-Kommentar #$existing_id aktualisiert."
    else
      echo "::warning title=Kommentar-PATCH fehlgeschlagen::Best-effort."
    fi
  else
    if gh_retry gh pr comment "$PR" --repo "$REPO" --body-file "$WORK/comment.md"; then
      echo "💬 Documenter-Kommentar erstellt."
    else
      echo "::warning title=Kommentar-POST fehlgeschlagen::Best-effort."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 4) Labels — ai:documented ZULETZT (erst wenn die Arbeit steht)
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" != "true" ]; then
  if [ "$HAS_RELEASE" != "true" ]; then
    gh_retry gh pr edit "$PR" --repo "$REPO" --add-label "$(release_label "$CLASSIFICATION")" \
      || echo "::warning title=release-Label fehlgeschlagen::Best-effort."
  fi
  gh_retry gh pr edit "$PR" --repo "$REPO" --add-label ai:documented || {
    echo "::error title=ai:documented nicht setzbar::Re-Run ist möglich (Precheck greift nicht)."
    exit 1
  }
fi

echo "✅ Rendering abgeschlossen: classification=$CLASSIFICATION title_changed=$([ -n "$NEW_TITLE" ] && echo true || echo false)"
