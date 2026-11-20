# Organizer

App macOS native (SwiftUI) pour organiser ses tâches pro et perso et suivre son temps, façon Clockify.

- **Chrono** avec badge dans la barre de menus, entrées liées aux tâches
- **Tableau** À faire / En cours / Terminée alimenté par un **Backlog**
- **Facettes** : un filtre global qui détermine ce que montre toute l'app (tâches, temps, notes, artifacts, projets)
- **Notes** (Markdown) et **Artifacts** (liens vers documents / artifacts Claude)
- **Rapports** sur n'importe quelle période, export CSV
- Intégrations : import **Clockify**, synchro bidirectionnelle **Jira**, **GitLab** (MR liées aux tickets)
- **API REST locale** pour piloter l'app depuis des scripts ou Claude (voir [CLAUDE.md](CLAUDE.md))

## Build

```bash
./scripts/build-app.sh            # build/Organizer.app
./scripts/build-app.sh --install  # copie dans /Applications
```

Nécessite macOS 14+ et Xcode / Swift 5.10+. Les données sont stockées localement dans
`~/Library/Application Support/Organizer/`.
