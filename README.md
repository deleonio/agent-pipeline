# agent-pipeline

Wiederverwendbare KI-Ticket-Pipeline (7 Phasen: Triage → UX → Spec → Umsetzung →
Review ↔ Fixup → Dokumentation) als **Reusable Workflows**. Die Engine (Composite
Actions, Scripts, Prompts, Job-Logik) liegt hier; Konsumenten-Repos halten nur
dünne Dispatcher-Stubs und laufen trotzdem vollständig im eigenen Kontext.

## Architektur in Kürze

- **Stub (im Konsumenten-Repo)**: `on:`-Trigger, `name:`, `concurrency:`
  (einziger Ort — im Callee wäre sie unzuverlässig), Permissions-Union,
  Event-Fakten-Filter + Fork-Guards als job-`if:`, `uses: …@<Minor-Tag>`,
  explizite Secrets (kein `secrets: inherit` — cross-repo nicht zuverlässig).
- **Callee (dieses Repo)**: `on: workflow_call` + Inputs. `github.*` und `vars.*`
  lösen caller-seitig auf — Label-Kette, Memory-Artefakte (`claude-memory-issue-{N}`)
  und Gate-Namens-Matching laufen therefore unverändert im Konsumenten-Repo.
- **Scripts/Prompts**: setup-claude checkt dieses Repo per App-Token nach
  `.agent-pipeline/` aus. Lokale `.github/prompts/*.md` des Konsumenten gewinnen
  gegen die zentralen Kopien (Override-Muster).
- **Vertrag**: Stub-Dateinamen + `name:`-Felder sind load-bearing
  (gate-merge-Allowlist `['CI','5/7 Review']`, Sweep-Dispatch
  `07-claude-pr-documenter.yml`, pr-cancel iteriert Dateinamen). **Nie umbenennen.**

## Konsumenten-Repo einrichten

1. GitHub App installieren: auf dem Konsumenten-Repo **und** auf diesem Repo
   (lesend genügt) — Permissions Contents/Issues/Pull requests/Actions.
2. Secrets setzen: `APP_ID`, `APP_PRIVATE_KEY` + je Provider-Key
   (`CLAUDE_API_KEY` | `ZAI_API_KEY` | `OPENROUTER_API_KEY`), optional
   `TAILSCALE_AUTH_KEY`.
3. Optional Vars: `LLM_PROVIDER` (claude|zai|openrouter, Default claude),
   `CLAUDE_MODEL_*` (Defaults: fable/sonnet/opus/haiku je Phase),
   `CLAUDE_CODE_SETTINGS_LOCAL_*`, `TAILSCALE_EXIT_NODE`.
4. Entfällt seit dem Public-Wechsel: Das Repo ist öffentlich — jede
   Konsumenten-Sichtbarkeit (privat oder public) kann konsumieren. (Die frühere
   Access-Freigabe galt nur privat-zu-privat; ein öffentlicher Konsument konnte
   private Provider NICHT auflösen — HTTP 422, am 17.08.2026 live belegt.)
5. Bootstrap (aus der Wurzel des Konsumenten-Repos):

   ```bash
   gh api repos/deleonio/agent-pipeline/contents/init.sh \
     -H "Accept: application/vnd.github.raw" > init.sh
   bash init.sh --tag v1.0 && rm init.sh
   ```

6. Stubs committen. Labels legt die Pipeline idempotent selbst an.

Repo-spezifische Konfiguration läuft über Stub-Inputs: `install-command`,
`node-version-file`, `test-paths`, `verify-command`, `ci-workflow-name`,
`merge-method`, `skip-ux` (siehe Stubs/`stubs/`).

## Release-Runbook (Minor-Tags)

- `main` = Entwicklung. **Branch-Protection ist auf privaten Repos nicht verfügbar
  (GitHub Free) — Ersatz-Disziplin:** Änderungen nur über Commits + Tags mit
  Runbook, kein Force-Push, kein Tag-Move nach Konsumenten-Pin. Bei einem
  GitHub-Pro-Upgrade: Protection auf main nachholen (kein Direktpush, kein
  Force-Push).
- Release: PR mergen → Checklist:
  1. Defaults synchronisieren: `pipeline-ref`-Default in
     `.github/actions/setup-claude/action.yml`, die `Ref v1.x`-Zeilen der
     Versions-Echo-Steps und die `@v1.x`-Pins der Stubs auf den neuen Tag setzen.
  2. Commit als Tag `v1.<n>` pushen.
  3. Konsumenten updaten: `init.sh --tag v1.<n>` im jeweiligen Repo (Re-Pin).
- Grundregel: Stubs pinnen **Minor-Tags**, nie ein bewegliches `v1` — ein
  beweglicher Tag schaltet alle Konsumenten gleichzeitig um (Phasen laufen teils
  mit `--dangerously-skip-permissions`; größter Supply-Chain-Hebel).

## Rollback

- Pipeline-Änderung zurücknehmen: Re-Pin auf den vorigen Minor-Tag
  (`init.sh --tag v1.<n-1>`) — Callee-Logik ist versioniert, Stubs ändern sich nicht.
- Komplette Rückkehr zur repo-lokalen Pipeline: Revert des Stub-PRs im
  Konsumenten-Repo (Kill-Switch).

## Trust-Boundaries & Supply Chain

- Dieses Repo enthält **keine Secrets** (nur Durchreicherei über
  `workflow_call.secrets`). Audit-Regel: so halten.
- Repo ist öffentlich (seit 17.08.2026, secret-frei auditiert): jeder kann die
  Workflows lesen und konsumieren — Vertrauensgrenze bleibt der eigene Account
  für Schreibzugriffe (Branch-Protection: kein Direktpush, kein Force-Push).
- Wer dieses Repo kompromittiert, führt Code in allen Konsumenten aus — deshalb:
  Minor-Tag-Pinning, keine beweglichen Refs in Stubs und (nach Pro-Upgrade)
  Branch-Protection auf main.
- Fork-PRs: Guards leben als Stub-job-`if:` VOR dem Call; der Callee wird bei
  Forks nie erreicht.

## Smoke-Test (ohne Secrets)

`.github/workflows/smoke.yml` verifiziert Remote-Auflösung, caller-seitige
vars/github-Kontexte, Stub-Concurrency und Artefakt-Landung im Konsumenten-Repo
(Plan-Checkliste a–d, f). App-Token-Checkout (e) und Fork-Guard (g) sind im
Pilot zu verifizieren.

## Nicht hier (bleibt im Konsumenten-Repo)

App-CI/Deploy (ci.yml, deploy, codeql, renovate), `.ai-knowledge/`,
`.claude/commands/`, `.mcp.json`, spec-/guide-sync, Helper-Workflows
(pr-cancel, conflict-scan, issue-unblock, pr-needs-review-label).
