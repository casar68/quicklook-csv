# QuickLook CSV — migration vers Preview/Thumbnail Extensions

Date : 2026-09-23
Statut : validé en brainstorming, prêt pour plan d'implémentation

## Contexte

Le plugin `.qlgenerator` legacy (`QuickLookCSV.qlgenerator`, ciblé par le CFPlugIn
défini dans `main.c`) repose sur des API QuickLook dépréciées depuis macOS 12
(`QLPreviewRequestIsCancelled`, `QLPreviewRequestSetDataRepresentation`,
`QLThumbnailRequestIsCancelled`, `QLThumbnailRequestCreateContext`,
`QLThumbnailRequestFlushContext`). Ces appels sont désormais annotés dans le code
(`GeneratePreviewForURL.m`, `GenerateThumbnailForURL.m`) pour indiquer que la
migration fait l'objet de ce chantier séparé.

Une revue de code préalable a corrigé, sur le target legacy : une injection HTML
dans l'aperçu (cellules non échappées), un dépassement de buffer + race condition
dans `formatFilesize()`, un off-by-one sur le cap `maxRows`, une clé `NSError`
invalide, et plusieurs warnings de compilation non liés à la dépréciation. Le
target legacy est conservé tel quel en parallèle pendant la validation de cette
nouvelle version ; sa suppression fera l'objet d'une PR ultérieure séparée.

## Objectif

Remplacer le modèle `.qlgenerator` par une **Preview Extension** et une
**Thumbnail Extension** modernes, hébergées dans une app hôte minimale, dans ce
même dépôt (historique Git continu). L'aperçu devient une vue SwiftUI native
(`Table`) au lieu d'un rendu HTML/CSS ; la miniature réutilise le dessin Core
Graphics existant.

## Décisions validées

| Décision | Choix |
|---|---|
| Emplacement | Nouveaux targets dans ce repo existant (pas de nouveau dépôt) |
| Langage du nouveau code | Swift (app hôte + 2 extensions) ; `CSVDocument`/`CSVRowObject` restent en Objective-C, partagés via bridging header |
| Cible de déploiement | macOS 13.0 |
| Devenir du legacy | Conservé en parallèle pour l'instant ; suppression prévue dans une PR ultérieure séparée |
| Rendu de l'aperçu | SwiftUI natif (`Table`, via `NSHostingController`) — pas de HTML/WebView |
| Rendu de la miniature | Core Graphics existant, réutilisé quasiment tel quel |
| Lecture de fichier | Passage en streaming (voir section dédiée), à la fois pour la Preview et la Thumbnail Extension |
| Tests | Ajout d'un target de test (framework **Testing**) — absent aujourd'hui du projet |

## Architecture & targets

Le projet Xcode existant gagne 3 nouveaux targets, en plus du `.qlgenerator`
legacy (inchangé) :

- **`QuickLookCSVApp`** — app hôte minimale, obligatoire pour héberger des
  extensions macOS. Aucune fonctionnalité propre : un écran simple renvoyant
  vers Réglages Système > Extensions si besoin. L'utilisateur n'a jamais besoin
  de la lancer ; macOS l'installe et active les extensions automatiquement une
  fois l'app placée dans `/Applications`.
- **`QuickLookCSVPreview`** — Preview Extension (`com.apple.quicklook.preview`),
  embarquée dans l'app hôte. Contient un `NSHostingController` hébergeant une
  vue SwiftUI qui affiche les données parsées.
- **`QuickLookCSVThumbnail`** — Thumbnail Extension
  (`com.apple.quicklook.thumbnail`), embarquée dans l'app hôte. Contient un
  `QLThumbnailProvider` qui réutilise le dessin Core Graphics de
  `GenerateThumbnailForURL.m`.

**Code partagé** : `CSVDocument.h/.m` et `CSVRowObject.h/.m` restent en
Objective-C, inchangés dans leur API existante (voir section streaming pour
l'ajout additif), et sont ajoutés comme membres des deux nouveaux targets
d'extension (pas de duplication) via un bridging header côté Swift.

## Composants & flux de données

- **`CSVPreviewViewController`** (Swift, `QuickLookCSVPreview`) — conforme à
  `QLPreviewingController`, implémente
  `preparePreviewOfFile(at:completionHandler:)`. Reprend la même logique de
  détection d'encodage que l'actuel `GeneratePreviewForURL.m` (UTF-8/natif →
  fallback ISO-8859-1, désormais sur préfixe borné — voir streaming), parse via
  `CSVDocument`, puis construit un view-model (`rows`, `columnKeys`, taille
  fichier, séparateur, encodage) passé à la vue SwiftUI. Pas de vérification de
  cancellation à faire manuellement : le nouveau modèle d'extension gère lui-même
  l'annulation/le teardown.
- **`CSVPreviewView`** (SwiftUI) — un `Table` macOS natif avec colonnes
  dynamiques (générées depuis `columnKeys`, le nombre de colonnes n'étant connu
  qu'à l'exécution), un bandeau d'info en tête (nb colonnes/lignes, taille,
  séparateur, encodage — équivalent du `.file_info` actuel) et un message si
  tronqué à `MAX_ROWS`. Aucune notion de HTML/CSS : `Style.css` reste utilisé
  uniquement par le target legacy. Bénéfice structurel : `Text` SwiftUI
  n'interprète jamais de markup, donc la classe de bug "injection HTML" déjà
  corrigée sur le legacy devient impossible ici par construction.
- **`CSVThumbnailProvider`** (Swift, `QuickLookCSVThumbnail`) — sous-classe de
  `QLThumbnailProvider`, implémente `provideThumbnail(for:_:)`. Reprend le
  dessin Core Graphics existant (grille, alternance de lignes, badge
  "csv"/"tab"), simplifié : `QLThumbnailReply(contextSize:currentContextDrawing:)`
  fournit déjà un `CGContext` prêt à l'emploi — plus besoin de
  `createRGBABitmapContext`, de gestion manuelle du buffer bitmap, ni du
  `free()` associé. Le cap `NUM_ROWS` (déjà corrigé côté off-by-one) reste
  inchangé.

**Flux** : Finder/QuickLook route un fichier `.csv`/`.tsv` (mêmes UTIs
`public.comma-separated-values-text` / `public.tab-separated-values-text`,
déclarées cette fois dans l'`Info.plist` de chaque extension via
`QLSupportedContentTypes`) vers l'extension appropriée → parse → affichage
(SwiftUI vivant pour l'aperçu, dessin direct pour la miniature).

## Lecture en streaming

Motivation : les extensions ont un budget mémoire/temps plus strict que
l'ancien plugin — un CSV de plusieurs Go chargé entièrement en mémoire
(comportement actuel du legacy, connu et documenté comme limite) pourrait faire
tuer l'extension par le système (jetsam) avant même qu'elle ait pu répondre.
Puisqu'on réécrit ce chemin pour la migration, on en profite pour le corriger.

Le parseur `NSScanner` actuel gère des subtilités (champs entre guillemets
contenant des retours à la ligne) qu'un simple split ligne-par-ligne casserait.
On garde donc la même machine à états, mais on la fait tourner sur des chunks
lus au fil de l'eau (`NSFileHandle`, ~64 Ko par lecture) au lieu de la chaîne
entière :

- **Détection encodage/séparateur** : faite sur un préfixe borné (~64 Ko, comme
  le font navigateurs/éditeurs pour les gros fichiers) plutôt que sur le
  fichier entier.
- **Parsing** : on accumule les chunks dans un buffer et on relance le scan
  progressivement, en ne committant que les lignes complètes ; un champ entre
  guillemets qui traverse une frontière de chunk est simplement complété par le
  chunk suivant avant d'être re-scanné.
- **Arrêt anticipé** : dès que `maxRows`/`NUM_ROWS` lignes sont capturées, on
  arrête de lire — pour un aperçu limité à 500 lignes, on ne lit typiquement que
  les premiers Ko du fichier, quelle que soit sa taille réelle.
- Ajout **additif** à `CSVDocument` : nouvelle méthode
  `numRowsFromFileAtURL:maxRows:error:`. La méthode actuelle basée sur
  `NSString` (`numRowsFromCSVString:maxRows:error:`) reste intacte et continue
  à servir le target legacy, inchangé.

## Gestion des erreurs & cas limites

- **Encodage/lecture** : même chaîne de fallback qu'avant (UTF-8/natif →
  ISO-8859-1, désormais sur préfixe borné). Si les deux échouent, on appelle le
  `completionHandler` avec une `NSError` — Quick Look affiche alors un aperçu
  générique au lieu de rien.
- **Fichier vide / 0 ligne** : `CSVDocument` retourne déjà une erreur propre.
  L'aperçu affiche un état "fichier vide" plutôt qu'un tableau vide ; la
  miniature ne dessine rien (comportement identique à l'actuel, fallback sur
  l'icône générique).
- **Annulation** : gérée par le système, pas de check manuel nécessaire.
- **Concurrence** : chaque extension tourne dans son propre processus
  sandboxé géré par le système — le type de hasard cross-thread corrigé sur
  `formatFilesize` (buffer `static`) ne peut plus se reproduire de cette façon.

## Plan de test

- **Build/manuel** : build de l'app hôte + 2 extensions, Quick Look sur
  `test.csv`/`testHeight.csv`/`testWidth.csv`/`testMini.csv` (tri des colonnes,
  redimensionnement, miniature avec badge).
- **Automatisé** : ajout d'un nouveau target de test avec le framework
  **Testing**, couvrant `CSVDocument` : guillemets/échappement, auto-détection
  de séparateur, cap `maxRows`, et le nouveau chemin streaming comparé à
  l'ancien chemin `NSString` (même résultat attendu sur les fixtures
  existantes).

## Hors périmètre

- Suppression du target legacy `.qlgenerator` (PR séparée ultérieure).
- Réécriture de la miniature en SwiftUI/`ImageRenderer` (pas de bénéfice
  identifié par rapport au Core Graphics existant).
- Toute nouvelle fonctionnalité utilisateur au-delà de la parité avec le
  comportement actuel (tri de colonnes mis à part, qui est un bénéfice gratuit
  du composant `Table` natif).
