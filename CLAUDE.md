# Coucou (Notch Buddy) — règles du projet

App macOS **perso** de Louis. Un petit personnage (piste « Mochi ») vit dans le notch du MacBook et montre ce que font ses agents : sessions Claude Code et workflows n8n. On peut tout faire depuis le notch : approuver, répondre, relancer, sauter au terminal, lancer une recherche Claude sur une fenêtre, déposer un fichier pour un prompt ou un mail.

Pas d'App Store, pas de distribution. Un seul Mac, un seul utilisateur.

## Sources de vérité (dans cet ordre)

1. `design/prototype/notch-buddy.html` : prototype validé par Louis. **Le visuel, le personnage, les timings, les couleurs et les sons de l'app doivent être identiques.** Le moteur du personnage (classe `Bot` : `update()`, `draw()`, `eye()`) est à porter en Swift **ligne à ligne**, mêmes constantes, mêmes formules.
2. `docs/SPEC.md` : comportement, dimensions, états, vues.
3. `docs/INTEGRATIONS.md` : Claude Code, n8n, API Claude, Mail, fenêtres, fichiers.
4. `design/captures/*.png` : captures cibles du prototype (Mochi) pour la QA visuelle.
5. `NotchBuddy/Resources/sounds/*.wav` : sons rendus depuis le prototype. Les utiliser tels quels, ne pas en synthétiser d'autres.

Si la spec et le prototype divergent sur un détail visuel, **le prototype gagne**. Si un doc Anthropic officiel contredit `INTEGRATIONS.md` (format des hooks, noms de modèles, outil de recherche web), **le doc officiel gagne** : vérifie-le avant d'implémenter.

## Rangement du dossier

- `NotchBuddy/` : l'app (code dans `Sources/`, sons dans `Resources/sounds/`, projet généré par `project.yml`).
- `docs/` : `SPEC.md`, `INTEGRATIONS.md`. `docs/historique/` : anciens documents, pour mémoire seulement.
- `design/` : prototype, captures cibles, séquences d'animation de référence.
- `video/` : la vidéo de présentation et sa musique.

Le mode tournage, le Studio 9:16 et le menu Debug ont été retirés : ne pas les recréer.

## Stack imposée

- Swift 6, SwiftUI + AppKit. Pas d'Electron, pas de web view pour l'UI.
- Projet généré avec **XcodeGen** (`project.yml` versionné) ; build avec `xcodebuild`. Installer XcodeGen avec Homebrew si absent.
- Cible de déploiement = la version de macOS installée sur ce Mac (`sw_vers -productVersion`).
- App agent : `LSUIElement = YES` (pas d'icône dans le Dock), petit item dans la barre de menus pour les réglages.
- Pas de sandbox. Signature « Sign to Run Locally ».
- Secrets (clé API Anthropic, clé API n8n) dans le **Trousseau**, jamais en clair sur disque ni dans git.
- Aucune dépendance tierce sauf si vraiment indispensable. Pas de Rive : le personnage est codé (SwiftUI `Canvas` + `TimelineView`).

## Façon de travailler

- Enchaîne les jalons M0 → M9 de `docs/SPEC.md` **sans demander de validation entre eux**. Louis ne veut rien avoir à faire.
- Les seules raisons de t'arrêter pour lui parler :
  1. Xcode absent (il doit l'installer depuis l'App Store).
  2. Saisir une clé API (tu ouvres la fenêtre Réglages de l'app, il colle la clé).
  3. Valider le diff de `~/.claude/settings.json` avant écriture (voir INTEGRATIONS.md).
  4. Cliquer une autorisation macOS (Enregistrement de l'écran, Automatisation pour Mail/Safari/Terminal).
- À la fin de **chaque** jalon :
  1. `xcodebuild` sans warning nouveau.
  2. Lance l'app et déclenche les états concernés.
  3. Capture la zone du notch avec `screencapture -x -R x,y,w,h` et **compare-la visuellement** aux fichiers de `design/captures/`. Corrige jusqu'à ce que ça corresponde.
  4. `git commit` avec un message clair.
  5. Donne à Louis un résumé de 3 lignes maximum, en français.
- Tests unitaires pour la logique pure : machine à états de l'island, parsing des événements de hooks, parsing de l'API n8n, réponse de l'API Claude.

## Interdits

- Ne jamais écraser `~/.claude/settings.json` : sauvegarde datée, fusion, diff montré à Louis, puis écriture.
- Ne jamais envoyer un mail sans clic explicite sur « Envoyer ».
- Ne jamais approuver une permission Claude Code sans clic explicite (sauf règle « Toujours autoriser » créée par Louis).
- Pas de télémétrie, pas d'appel réseau autre que : API Anthropic, instance n8n de Louis.
- Ne pas bloquer une session Claude Code : si l'app est fermée ou ne répond pas, le hook rend la main immédiatement au terminal.
- Performance : 0 % CPU quand l'island est masquée (animations en pause), moins de 3 % en compact.

## Langue

UI en français, phrases courtes, pas de jargon. Code, identifiants et commentaires en anglais.
