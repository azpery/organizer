# Organizer — app macOS de tâches + suivi du temps

App SwiftUI native (macOS 14+), Swift Package sans projet Xcode. Données locales en SQLite.

- Build + bundle : `./scripts/build-app.sh` → `build/Organizer.app` (`--install` copie dans /Applications)
- Dev : `swift build`
- Données : `~/Library/Application Support/Organizer/organizer.sqlite`
- Préférences (clés Clockify/Jira, port, token, profil) : `defaults read local.organizer.app`
- Rien de personnel dans le dépôt : noms de clients, clé Jira, profil et facettes vivent dans les préférences et la base locale. Le contexte propre à l'utilisateur est dans `CLAUDE.local.md` (non suivi par git).

## Piloter les tâches via l'API locale

L'app expose une API REST sur `127.0.0.1` (port 47821 par défaut) quand elle tourne.
URL et token sont dans `~/Library/Application Support/Organizer/api.json`.

```bash
T=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/Library/Application Support/Organizer/api.json')))['token'])")
curl -s -H "Authorization: Bearer $T" http://127.0.0.1:47821/api/tasks?status=todo,in_progress
```

`GET /api/health` (sans token) liste toutes les routes. Principales :

| Route | Usage |
|---|---|
| `GET /api/mindmaps` · `POST /api/mindmaps` {title, labels, children:[{text, task_id?, note_id?, collapsed?, children}]} · `GET/PATCH/DELETE /api/mindmaps/{id}` · `POST /api/mindmaps/{id}/nodes` | cartes mentales |
| `GET /api/tasks?status=&context=&project=&label=&q=` | lister (status : backlog, todo, in_progress, almost_done (Presque terminé ↔ Jira « Revue en cours »), done ; plusieurs séparés par `,`) |
| `POST /api/tasks` | créer `{title, project?, labels?, status?, context?, priority?, jira_key?, due_date?, estimate_minutes?, notes?}` |
| `POST /api/tasks/batch` | `{tasks: [...]}` |
| `PATCH /api/tasks/{id}` | modifier (mêmes champs) |
| `POST /api/tasks/{id}/move` | `{status}` |
| `POST /api/tasks/{id}/jira` | créer le ticket Jira correspondant et le relier |
| `GET /api/tasks/{id}/context` | fiche complète (description Jira en Markdown, commentaires, liens, notes, artifacts, temps) |
| `POST /api/ui/open/{id\|CLÉ-n}` | ouvrir la fiche d'une tâche dans l'app |
| `GET /api/labels`, `POST /api/labels {name}`, `DELETE /api/labels/{name}` | facettes |
| `POST /api/import/jira {jql?}` | import des tickets du projet Jira configuré (défaut : tout le projet) |
| `POST /api/gitlab/refresh` | rafraîchir les MR GitLab liées (visibles dans `GET /api/tasks/{id}` → `merge_requests`) |
| `GET/POST/PATCH/DELETE /api/notes` | notes Markdown `{title, body, append?, labels, task_id?\|jira_key?, pinned?}` |
| `GET/POST/PATCH/DELETE /api/artifacts` | artifacts / liens `{title, url, kind, summary, labels, task_id?\|jira_key?}` (POST sur une URL existante = mise à jour) |
| `GET /api/overview?label=` | tout ce qui appartient à une facette (projets, tâches, notes, artifacts) |
| `GET /api/today`, `POST /api/today/plan` | suggestions du jour, plan généré par Ollama (tient compte de l'agenda) |
| `GET /api/calendar?date=` | événements Google Agenda + créneaux libres |
| `POST /api/calendar/prepare {title?\|index?}` | note de préparation de réunion (Ollama : notes, tâches, mails liés) |
| `GET /api/mails?q=&unread=1`, `POST /api/mails/sync` | mails récents (copie locale depuis Apple Mail) |
| `PATCH /api/labels/{name} {name?, position?}` | renommer / fusionner / réordonner une facette |
| `GET/POST /api/clients`, `PATCH /api/clients/{id}` | clients facturés (adresse, TVA, taux, devise, régime TVA, projets rattachés) |
| `POST /api/invoices/generate {client, from, to, grouping?}` | brouillon de facture depuis le temps non facturé |
| `GET /api/invoices`, `PATCH/DELETE /api/invoices/{id}`, `POST /api/invoices/{id}/pdf` | factures, statut, export PDF (Documents/Factures) |
| `GET/POST/PATCH/DELETE /api/time-entries` | entrées de temps (`start`, `end` ou `duration_minutes`, `task_id`, `project`) |
| `POST /api/timer/start` / `stop`, `GET /api/timer` | chrono |
| `GET /api/reports/summary?from=YYYY-MM-DD&to=YYYY-MM-DD` | temps par projet / tâche / jour |
| `POST /api/import/clockify {from?, to?}` | import Clockify |

Notes :
- `project` accepte le nom du projet (insensible à la casse) à la place de `project_id`.
- Les facettes (`labels`) réutilisent l'orthographe existante sans tenir compte de la casse.
- Une tâche avec `jira_key` (projet Jira configuré) répercute dans Jira ses changements de statut, de titre et d'échéance, si Jira est configuré.
- `PATCH /api/tasks/{id}` avec `"sync_jira": false` n'envoie rien à Jira (utile pour des imports en masse).
- Facettes : libres, une par client ou par sujet ; la facette « en attente » (Réglages › Profil, défaut `⏳ En attente`) est transversale : tickets en attente côté client. Liste réelle : `GET /api/labels`.
- Notes Apple importées : `external_id` = id Apple Notes (lecture seule dans l'app). Les notes sensibles (identifiants, IBAN, codes) ne sont jamais importées.
- Préparations de réunion : `external_id` = `gcal:<event>:<jour>`, générées 1 h avant si `autoPrep`.
- Démarrer le chrono sur une tâche backlog/todo la passe en `in_progress`.

## Règle pour Claude

Quand tu crées un artifact (page claude.ai, document, design…) ou une note de travail pour l'utilisateur,
enregistre-le dans l'app : `POST /api/artifacts` (avec l'URL) ou `POST /api/notes`, avec les facettes
pertinentes et `jira_key` si ça concerne un ticket. Les facettes pilotent tout ce que l'app affiche.

## Architecture

- `Store.swift` : état @MainActor + persistance ; toute mutation passe par `upsertTask/upsertEntry/...`
- `Database.swift` : wrapper SQLite + migrations (`PRAGMA user_version`)
- `APIServer.swift` (Network.framework) + `APIRouter.swift` (routes JSON)
- `ClockifyImporter.swift`, `JiraClient.swift` (import + push Jira)
- `StatusItem.swift` : badge chrono dans la barre de menus (AppKit ; `MenuBarExtra` + `Text(.timer)` provoquait une boucle de layout)
- `Invoicing.swift` : clients, numérotation F-AAAA-NNN, génération depuis le temps (arrondi), PDF A4 (ImageRenderer) ; les entrées facturées portent `invoice_id`
- `Planner.swift` : suggestions du jour (score) + plan IA via Ollama (`qwen3:8b` par défaut)
- `OllamaService.swift` : interrupteur Ollama (`brew services run/stop ollama`, jamais enregistré au login) ; `OllamaToggle` dans Réglages et l'Assistant
- `GenerativeArt.swift` + `Views/GenerativeArtView.swift` : onglet Generative art (10 styles animables dessinés dans un `Canvas`, RNG à graine `SeededRNG`, palettes, export PNG / presse-papiers / fond d'écran)
- `GitLab.swift` : MR liées aux tickets par leur clé
- `MailSource.swift` : lecture Apple Mail via JXA (`osascript`), copie locale table `mails` (fenêtre glissante)
- `MeetingPrep.swift` : contexte (mots-clés → notes/tâches/mails) + note de prépa via Ollama
- `GoogleCalendar.swift` : OAuth Google (loopback + PKCE, refresh token dans `google.json` 0600), événements, créneaux libres
- `DiskCleaner.swift` + `Views/CleanerView.swift` : onglet Nettoyage (caches, builds de projets, gros fichiers, corbeille, désinstallation d'apps) ; caches supprimés définitivement, fichiers perso et apps → corbeille ; garde-fou `DiskScan.isRemovable` ; volontairement pas exposé dans l'API
- `Profile` (Models.swift) : prénom + présentation de l'utilisateur injectés dans les prompts Ollama ; `Facets.waiting`, `Jira.projectKey`, `Jira.defaultProjectName` : tous lus dans les préférences, défauts neutres
- `Demo.swift` : mode démo (`ORGANIZER_DEMO_DIR`) : données isolées, port 47899, aucune synchronisation, faux résultats de nettoyage, capture de la fenêtre (`ORGANIZER_SHOT`) ; `scripts/demo-data.py` + `scripts/screenshots.sh` régénèrent `docs/screenshots` — les captures du README ne doivent jamais venir des vraies données
- `Views/` : Aujourd'hui, Chrono, Tableau (kanban), Backlog, Rapports, Projets, Réglages
