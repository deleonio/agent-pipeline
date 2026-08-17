#!/usr/bin/env bash
# Liefert offene PRs zu einem Issue — robust gegen fehlendes "#" im Closing-Keyword.
#
# GitHub belegt closingIssuesReferences NUR, wenn der PR-Body ein Closing-Keyword
# MIT "#" enthält ("Closes #123"). Schreibt der Agent "Closes 123" (ohne "#"),
# bleibt die Referenz leer — und Spec/Implement finden ihren eigenen PR nicht mehr
# (PR #585: Spec-Crash "VERDICT ready, aber kein Spec-PR mit Tests").
#
# Strategie: primär closingIssuesReferences; fällt die leer aus, Suche der
# Issue-Nummer im PR-Body ("NNN in:body") als deterministischer Fallback.
#
# Bash (kein .ts): reine jq-/gh-Wrapper-Logik, inline aus Workflow-Run-Blöcken.
#   pnpm dlx tsx für 3 Zeilen jq-Wrapper wäre Over-Engineering.
#
# Usage:
#   bash pr-for-issue.sh --repo <owner/repo> --issue <N> \
#                        [--draft yes|no|any] [--out first|all|count]
#   --draft yes = nur Drafts, no = nur Nicht-Drafts, any = beides (Default: any)
#   --out   first = erste Nummer (Default), all = alle Nummern (zeilenweise),
#                  count = Anzahl

set -uo pipefail

DRAFT="any"
OUT="first"
REPO=""
ISSUE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)  REPO="$2";  shift 2 ;;
    --issue) ISSUE="$2"; shift 2 ;;
    --draft) DRAFT="$2"; shift 2 ;;
    --out)   OUT="$2";   shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$REPO" ]  || { echo "pr-for-issue: --repo required" >&2; exit 2; }
[ -n "$ISSUE" ] || { echo "pr-for-issue: --issue required" >&2; exit 2; }

# Draft-Filter (jq-Fragment)
case "$DRAFT" in
  yes) DSEL='select(.isDraft == true)' ;;
  no)  DSEL='select(.isDraft == false)' ;;
  any) DSEL='.' ;;
  *)   echo "pr-for-issue: ungültiges --draft '$DRAFT'" >&2; exit 2 ;;
esac

# Ausgabe-Form (DSEL wird unten eingefügt)
case "$OUT" in
  first) FMT='[.[] | DSEL | .number] | (first // empty)' ;;
  all)   FMT='[.[] | DSEL | .number] | .[]' ;;
  count) FMT='[.[] | DSEL] | length' ;;
  *)     echo "pr-for-issue: ungültiges --out '$OUT'" >&2; exit 2 ;;
esac
FMT="${FMT/DSEL/$DSEL}"

query() {
  # $1 = jq-Programm (bereits auf . als PR-Liste ausgelegt)
  gh pr list --repo "$REPO" --state open --json number,isDraft,closingIssuesReferences \
    --jq "$1" 2>/dev/null || true
}

# 1) Primärpfad: closingIssuesReferences
res="$(query "[.[] | select((.closingIssuesReferences // []) | any(.number == ${ISSUE}))] | ${FMT}")"

# 2) Fallback: Issue-Nummer im Body ("Closes NNN" ohne "#").
#    Bei count ZUSÄTZLICH auf "0" triggern — `length` liefert nie leer, sondern "0",
#    sonst würde der Fallback im skip-guard (count) trotz fehlendem "#" nie greifen.
trigger=0
if [ "$OUT" = "count" ]; then
  { [ -z "$res" ] || [ "$res" = "null" ] || [ "$res" = "0" ]; } && trigger=1
else
  { [ -z "$res" ] || [ "$res" = "null" ]; } && trigger=1
fi
if [ "$trigger" = "1" ]; then
  res="$(gh pr list --repo "$REPO" --state open --search "${ISSUE} in:body" \
    --json number,isDraft --jq "${FMT}" 2>/dev/null || true)"
fi

# count → 0 statt leer (sonst crasht [ -gt 0 ] im Caller)
if [ "$OUT" = "count" ] && [ -z "$res" ]; then res="0"; fi

printf '%s' "$res"
