FOKUS: NUR Issue #ISSUE_NR. NUR rote Tests je Akzeptanzkriterium (mit Dedup), kein Produktivcode. KEINE Abstecher. Token sparen: kurz, präzise, direkt.

⚠️ KI-UX-Block: Falls das Issue UX-Aspekte hat (KI-UX:END-Block im Issue-Body vorhanden), UX-Anforderungen aus diesem Block bei der Spec-Ableitung beachten.

ABLAUF (STRIKT):
  1. SOFORT starten.
  2. Branch anlegen: git switch -c feat/issue-ISSUE_NR-<kurzname>.
     Akzeptanzkriterien primär aus BODY-BLOCK des Issues entnehmen:
     gh issue view ISSUE_NR --json body -q .body (Abschnitt zwischen <!-- KI-ANALYSE:START --> und <!-- KI-ANALYSE:END -->).
  3. SPEC-UPDATE (zuerst! SPEC-FIRST – spezifikation.*vor.*test – Spezifikation aktualisieren VOR Test-Ableitung):
     - Prüfen, ob ein relevanter Spec bereits existiert: ls docs/spec/*.md
     - FALLS JA (z.B. user-journeys.md für Feature-Änderungen): Existierenden Spec erweitern/korrigieren/kürzen – dokumentiere das Verhalten, das getestet werden soll.
     - FALLS NEIN: Neuen Spec docs/spec/issue-ISSUE_NR.md anlegen – strukturiert nach Ziel/Vorbedingung/Schritte/Erwartetes Ergebnis (siehe user-journeys.md als Format-Referenz).
     - Spec-Update im gleichen Commit wie die Tests (nicht separater Commit – Spec gehört zur Spec-Phase).
  4. ROTE Tests schreiben – abgeleitet aus dem Spec (nicht direkt aus den Akzeptanzkriterien). Jedes AK muss durch den Spec gedeckt sein. JEDER Test muss auf den Spec oder ein Akzeptanzkriterium Bezug nehmen. KEINE Tests ohne Spec-Bezug (all.*tests.*must.*reference.*spec). Vorab-Prüfung/validier.*test: Ist der Test im Spec gedeckt? Testebene nach Typ, NUR in Anwendungscode-Pfaden (server/src/**, frontend/src/**, frontend/e2e/**): Backend-Logik/API → server/src/{logics,express}/*.test.ts (node:test); Frontend-Logik → frontend/src/lib/*.test.ts (Vitest); Feature/UI-Verhalten → frontend/e2e/*.spec.ts (Akzeptanz-e2e); reines Styling/Layout → keinen Test erzwingen, stattdessen im PR-Body visuell begründen.
     TEST-QUALITÄT (Test-Konzept — KEINE dogmatische Coverage): ein Test gehört in den PR NUR, wenn er mind. EINES leistet — (a) Auswertung: rechnet etwas aus, das nicht wörtlich in der Quelle steht; (b) Spiegel: sichert Konsistenz zwischen Dateien, Sollwert aus der führenden Quelle gelesen (nie als Literal in den Test geschrieben); (c) Schutz: vor stillen/teuren Ausfällen (Datenverlust, Secret-Leak, Endlosschleife, still übersprungene Suite). KEIN Test der Form „Datei enthält den String, den ich geschrieben habe" (Change-Detector — findet per Konstruktion keinen Fehler). KEIN Test für Fehler, die beim nächsten Lauf ohnehin laut krachen. Lieber 3 Tests mit Biss als 12 Statistik-Füller.
     NICHT-ANWENDUNGSCODE-CARVE-OUT: Tests sind NUR für Anwendungscode (server/src/**, frontend/src/**, frontend/e2e/**). KEINE Tests für .github/workflows, .github/scripts, setup-claude-Composite-Actions, CI-Plumbing (ci.yml/deploy.yml), Config-Dateien (yml/json/toml) ODER Markdown-Inhalt (jede .md-Datei, egal wo — nicht nur unter docs/; auch KEIN Test, der den Spec .github/prompts/*.md oder docs/spec/*.md selbst prüft). String/YAML/Config-Match auf diese Dateien ist ein reiner Change-Detector („die Datei enthält den String, den ich hineingeschrieben habe") und fängt per Konstruktion keinen Fehler — siehe ADR 0001. Stattdessen im PR-Body die Akzeptanzkriterien durchgehen und je AC belegen (Zitat/Link), dass es erfüllt ist; der Review prüft die AC-Erfüllung im Text.
     VORAB Dedup: Prüfe per grep, ob ein AK bereits durch bestehenden Test abgedeckt ist.
       - Schon abgedeckt → NICHT duplizieren.
       - Widerspricht AK einem bestehenden Test → alten Test ENTFERNEN und im PR-Body im Abschnitt "Test-Pflege-Bedarf" dokumentieren (Datei:Zeile + Begründung).
     MUTATIONS-PROBE vor dem Commit: das bewachte Verhalten absichtlich brechen — wird der Test nicht rot, gehört er nicht in den PR. Bei All-Quantor-Tests („für alle X …") sicherstellen, dass überhaupt X gefunden werden (sonst dauerhaft grün über eine leere Menge).
     Bei Confirm-/Lösch-/Zerstör-Dialogen: Tests an docs/ux-pattern-sequential-confirmation.md orientieren – sequenzielle Ja/Nein-Schritte, verbindliches Fokus-Management beim Übergang.
  5. Rote Tests als ERSTEN Commit (test: rote Spec-Tests für #ISSUE_NR), Branch pushen.
     DRAFT-PR erstellen (gh pr create --draft) mit Closes #ISSUE_NR im Body. KEIN ai:needs-review setzen.

⚠️ LABELS: KEINE Labels setzen! Workflow übernimmt das automatisch.

VERDICT: GANZ AM ENDE GENAU EINE Zeile:
  - VERDICT: ready (rote Tests geschrieben + Draft-PR erstellt → gibt Issue zur Umsetzung frei)
  - VERDICT: spec-ready (Partial – Tests unvollständig, braucht Folgelauf)

EHRLICHKEITS-REGEL: VERDICT: ready NUR ausgeben, wenn Draft-PR tatsächlich existiert UND mindestens eine Test-Datei committed+gepusht ist (vorher mit gh pr view/git log verifizieren).

ZEITLIMIT: Soft-Deadline = SOFT_DEADLINE. Vor jedem Schritt: [ $(date +%s) -ge SOFT_DEADLINE ]. Bei OVER: aktuellen Stand committen+pushen als Draft-PR, Turn beenden.
