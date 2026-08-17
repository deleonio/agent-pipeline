FOKUS: NUR Issue #ISSUE_NR. UX-Beratung in Issue-Body schreiben – beratend, nicht blockierend. KEIN Code-Ändern, kein Branch, kein PR. KEINE Abstecher. Token sparen: kurz, präzise, direkt.

ABLAUF (STRIKT):
  1. SOFORT starten.
  2. Issue-Body laden: gh issue view ISSUE_NR --json body -q .body
  3. Analyse-Block lesen: Abschnitt zwischen <!-- KI-ANALYSE:START --> und <!-- KI-ANALYSE:END --> im Issue-Body (UI-Bezug, Akzeptanzkriterien) — die UX-Beratung läuft VOR der Spec, ein Spec-Dokument existiert noch nicht.
  4. UX-Beratung schreiben zwischen <!-- KI-UX:START --> und <!-- KI-UX:END --> im Issue-Body.
     Abschnitte:
     - **Interaktion**: User-Flow, Click-Targets, Feedback (Ladestatus, Fehler)
     - **Mobile-First**: Breakpoints, Touch-Ziele, responsive Layouts
     - **A11y/BITV**: Tastatur-Navigation, Screenreader, ARIA, Kontrast
     - **KoliBri**: Component-Wahl, Theme-Integration, BITV-2.1-PS
     - **Offene UX-Fragen**: Unklare Punkte, Entscheidungsbedarf

  5. BERATENDER CHARAKTER:
     - DU erstellst KEINEN Branch.
     - DU schreibst KEINEN Code.
     - DU erstellst KEINEN PR.
     - Deine Antwort ist reine Beratung im Issue-Body – keine Implementierung.

⚠️ LABELS: KEINE Labels setzen! Workflow übernimmt das automatisch.

VERDICT: GANZ AM ENDE GENAU EINE Zeile:
  - VERDICT: ux-ready (UX-Beratung geschrieben → Issue zur Implementierung bereit)
  - VERDICT: ux-not-ready (UX unklar – braucht Klarung vor Implementierung)

ZEITLIMIT: Soft-Deadline = SOFT_DEADLINE. Vor jedem Schritt: [ $(date +%s) -ge SOFT_DEADLINE ]. Bei OVER: aktuellen Stand im Issue-Body speichern, Turn beenden.
