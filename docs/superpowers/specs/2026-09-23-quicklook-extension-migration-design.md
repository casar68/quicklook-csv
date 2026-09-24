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
| Langage du nouveau code | Swift (app hôte + 2 extensions). `CSVDocument`/`CSVRowObject` restent en Objective-C, **exclusifs au target legacy** — le nouveau parseur streaming est une structure Swift native indépendante (voir streaming) |
| Cible de déploiement | macOS 13.0 |
| Devenir du legacy | Conservé en parallèle pour l'instant ; suppression prévue dans une PR ultérieure séparée |
| Rendu de l'aperçu | SwiftUI natif (`Table`, via `NSHostingController`) — pas de HTML/WebView |
| Rendu de la miniature | Core Graphics existant, réutilisé quasiment tel quel |
| Lecture de fichier | Streaming par scan d'octets/unités bruts (stride adapté à l'encodage) + fallback par cellule + plafonds de sécurité (voir section dédiée), pour la Preview et la Thumbnail Extension |
| Accès fichier sandbox | Appel défensif `startAccessingSecurityScopedResource()`/`stopAccessingSecurityScopedResource()` autour de la lecture (coût nul si non applicable ; à confirmer empiriquement, voir section streaming) |
| Parseur streaming | Structure Swift native, exclusive aux nouveaux targets — **pas** un ajout à `CSVDocument` (voir streaming). `CSVDocument`/`CSVRowObject` restent 100% cantonnés au target legacy ; la question du partage multi-target (tranchée au tour précédent) devient sans objet |
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

**Pas de code partagé avec le legacy** : `CSVDocument.h/.m` et `CSVRowObject.h/.m`
restent en Objective-C, **inchangés et exclusifs au target legacy**. Les
nouveaux targets n'en ont pas besoin : le parsing y est assuré par une
structure Swift native indépendante (voir streaming), donc pas de bridging
header ni de multi-target membership à mettre en place pour ces fichiers. La
question tranchée au tour précédent ("multi-target membership vs framework")
est donc devenue sans objet — il n'y a plus de code à partager entre legacy et
nouveaux targets.

## Composants & flux de données

- **`CSVStreamParser`** (Swift, code partagé *entre les deux nouveaux targets
  uniquement* — pas avec le legacy) — la structure native Swift qui remplace
  `CSVDocument` pour ce chemin (voir streaming pour l'algorithme). Produit un
  `ParsedCSVTable` : `columnKeys: [String]`, `rows: [CSVRow]` (avec
  `CSVRow: Identifiable`, `id` = index de ligne au moment du parsing — stable
  par construction, donc pas de wrapper supplémentaire nécessaire pour
  `Table`/`ForEach`), plus les métadonnées (taille fichier, séparateur,
  encodage détecté, indicateurs de troncature lignes/colonnes).
- **`CSVPreviewViewController`** (Swift, `QuickLookCSVPreview`) — conforme à
  `QLPreviewingController`, implémente
  `preparePreviewOfFile(at:completionHandler:)`. Enrobe la lecture d'un
  `startAccessingSecurityScopedResource()`/`stopAccessingSecurityScopedResource()`
  défensif (voir streaming), appelle `CSVStreamParser` pour obtenir un
  `ParsedCSVTable`, puis le passe à la vue SwiftUI. Pas de vérification de
  cancellation à faire manuellement : le nouveau modèle d'extension gère
  lui-même l'annulation/le teardown.
- **`CSVPreviewView`** (SwiftUI) — un `Table` macOS natif avec colonnes
  dynamiques (générées depuis `columnKeys`, plafonnées à `maxColumns` — voir
  streaming), un bandeau d'info en tête (nb colonnes/lignes, taille, séparateur,
  encodage — équivalent du `.file_info` actuel) et un message si tronqué en
  lignes et/ou en colonnes. Aucune notion de HTML/CSS : `Style.css` reste
  utilisé uniquement par le target legacy. Bénéfice structurel : `Text` SwiftUI
  n'interprète jamais de markup, donc la classe de bug "injection HTML" déjà
  corrigée sur le legacy devient impossible ici par construction.
- **`CSVThumbnailProvider`** (Swift, `QuickLookCSVThumbnail`) — sous-classe de
  `QLThumbnailProvider`, implémente `provideThumbnail(for:_:)`. Même wrap
  security-scoped défensif, même `CSVStreamParser`. Reprend le dessin Core
  Graphics existant (grille, alternance de lignes, badge "csv"/"tab") adapté
  pour consommer un `ParsedCSVTable` au lieu d'un `CSVDocument`/`CSVRowObject`,
  simplifié : `QLThumbnailReply(contextSize:currentContextDrawing:)` fournit
  déjà un `CGContext` prêt à l'emploi — plus besoin de
  `createRGBABitmapContext`, de gestion manuelle du buffer bitmap, ni du
  `free()` associé. Le cap `NUM_ROWS` (déjà corrigé côté off-by-one côté
  legacy) reste inchangé côté valeur.

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

**Accès fichier** : la lecture est enrobée d'un
`startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`
défensif. Les échantillons Apple pour les Preview/Thumbnail Extensions n'appellent
pas cette API — l'accès à l'URL fournie par le système semble déjà accordé pour
la durée de la requête — mais l'appel est sans effet (retourne `false`) sur une
URL qui n'est pas security-scoped, donc l'ajouter ne coûte rien et couvre le cas
où il s'avérerait nécessaire. À confirmer empiriquement dès la première
extension buildée.

**`CSVStreamParser`, une structure Swift native isolée du legacy** : manipuler
des flux d'octets bruts implique de l'arithmétique d'index sur des buffers —
exactement le type de code où une erreur manuelle en Objective-C réintroduirait
le genre de risque mémoire qu'on vient de corriger sur le target legacy
(`formatFilesize`). Ce chemin est exclusif aux nouveaux targets (jamais appelé
par le legacy), donc au lieu de le greffer sur `CSVDocument`, c'est une
structure Swift entièrement nouvelle et indépendante — `Data`/`Array` en Swift
sont bornés et vérifiés à l'exécution, contrairement à un pointeur C manuel.
**Conséquence acceptée** : il existe désormais deux implémentations
indépendantes de la grammaire CSV (le `NSScanner` en ObjC pour le legacy, ce
scanner d'octets en Swift pour le neuf) qui doivent rester comportementalement
identiques sur les cas comme le guillemet échappé (`""`) ou les retours à la
ligne dans une cellule entre guillemets — risque déjà couvert par le test de
non-régression prévu (voir Plan de test) qui compare les deux sur les fixtures
existantes.

Le parseur `NSScanner` actuel gère des subtilités (champs entre guillemets
contenant des retours à la ligne) qu'un simple split ligne-par-ligne
casserait. `CSVStreamParser` garde donc la même logique de machine à états,
mais la fait tourner sur des chunks lus au fil de l'eau (`NSFileHandle`, ~64 Ko
par lecture) au lieu de la chaîne entière :

- Le memory mapping (`NSDataReadingMappedIfSafe`) a été considéré mais écarté :
  il change uniquement *comment* les octets arrivent depuis le disque
  (pagination transparente par l'OS), pas *où* on découpe le texte pour le
  décoder — le risque de couper au milieu d'un caractère multi-octets existe
  de la même façon qu'avec des chunks lus explicitement.
- **Détection encodage/séparateur** : faite sur un préfixe borné (~64 Ko, comme
  le font navigateurs/éditeurs pour les gros fichiers) plutôt que sur le
  fichier entier, avec détection du BOM (`0xEF 0xBB 0xBF` UTF-8, `0xFF 0xFE`
  UTF-16LE, `0xFE 0xFF` UTF-16BE) en tout début de fichier.
- **Largeur de scan adaptée à l'encodage (correction du point le plus
  important de cette revue)** : pour UTF-8/ASCII/ISO-8859-1 (et Shift-JIS), les
  octets structurants du format (séparateur, guillemet, retour ligne — tous
  `< 0x80`) ne peuvent **jamais** apparaître comme octet de continuation UTF-8
  (`≥ 0x80`) ni comme octet de tête/suite Shift-JIS (toujours `≥ 0x40`), et en
  ISO-8859-1 chaque octet est déjà un caractère complet à lui seul — le scan
  peut donc se faire **octet par octet** en toute sécurité. **Ce n'est pas vrai
  pour UTF-16** : un caractère non-ASCII peut y produire par coïncidence
  l'octet `0x2C` (virgule) ou `0x22` (guillemet) à l'une des deux positions
  d'une unité de 16 bits (ex. U+222C → octets `[0x2C, 0x22]` en UTF-16LE), ce
  qui produirait un faux délimiteur avec un scan octet-par-octet. Si le BOM
  indique de l'UTF-16, `CSVStreamParser` scanne donc par **unités de 16 bits**
  (stride = 2 octets, endianness du BOM) et compare chaque unité à la valeur de
  code du délimiteur — jamais un octet isolé — ce qui élimine l'ambiguïté
  puisque les caractères structurants sont tous des points de code du plan de
  base sans lien avec les paires de substituts (`0xD800`–`0xDFFF`).
  Ne décoder en `NSString`/`String` qu'une fois qu'une cellule complète est
  identifiée (jamais au milieu d'un caractère), quel que soit le stride.
- **Fiabilité au-delà du préfixe** : si le décodage d'une cellule avec
  l'encodage détecté sur le préfixe échoue (cas d'un fichier ASCII sur les
  premiers 64 Ko puis contenant un octet ISO-8859-1 plus loin), on retente le
  décodage de **cette seule cellule** en ISO-8859-1, qui ne peut jamais échouer
  (tout octet y est un caractère valide) — pas besoin de relancer tout le
  parsing depuis le début.
- **Plafond mémoire par cellule/ligne** : un guillemet ouvrant jamais refermé
  ferait accumuler tout le reste du fichier dans une seule cellule sans jamais
  atteindre `maxRows` (la ligne 1 ne se termine jamais) — l'arrêt anticipé par
  nombre de lignes ne protège donc pas contre ce cas. `CSVStreamParser` impose
  une taille maximale (ex. 1 Mo) au buffer d'accumulation d'une cellule ; si
  dépassée, le parsing s'arrête en erreur plutôt que de continuer à consommer
  le fichier jusqu'à EOF.
- **Plafond de colonnes (`maxColumns`, ex. 50)** : un CSV à centaines de
  colonnes peut faire ramer le rendu natif de `Table` en colonnes dynamiques.
  Au-delà de `maxColumns`, `CSVStreamParser` continue de reconnaître
  correctement les limites de cellules/lignes (pour ne pas casser la détection
  de fin de ligne) mais arrête d'enregistrer de nouvelles clés de colonne ;
  `ParsedCSVTable` expose un indicateur de troncature horizontale, affiché dans
  le bandeau d'info au même titre que la troncature de lignes.
- **Arrêt anticipé** : dès que `maxRows`/`NUM_ROWS` lignes sont capturées, on
  arrête de lire — pour un aperçu limité à 500 lignes, on ne lit typiquement que
  les premiers Ko du fichier, quelle que soit sa taille réelle.

## Gestion des erreurs & cas limites

- **Encodage/lecture** : même chaîne de fallback qu'avant (UTF-8/natif →
  ISO-8859-1), détectée sur préfixe borné puis re-vérifiée par cellule au fil du
  parsing (voir streaming). Si la lecture du fichier échoue complètement (accès
  refusé, fichier disparu), on appelle le `completionHandler` avec une
  `NSError` — Quick Look affiche alors un aperçu générique au lieu de rien.
- **Fichier vide / 0 ligne** : `CSVStreamParser` retourne une erreur propre
  (même sémantique que `CSVDocument` côté legacy). L'aperçu affiche un état
  "fichier vide" plutôt qu'un tableau vide ; la miniature ne dessine rien
  (comportement identique à l'actuel, fallback sur l'icône générique).
- **Cellule/ligne malformée dépassant le plafond mémoire** (ex. guillemet non
  refermé) : `CSVStreamParser` s'arrête en erreur dès que le plafond par
  cellule est dépassé (voir streaming), plutôt que de continuer à consommer le
  fichier jusqu'à EOF. Traité comme une erreur de parsing ordinaire — aperçu
  générique / pas de miniature.
- **Annulation** : gérée par le système, pas de check manuel nécessaire.
- **Concurrence** : chaque extension tourne dans son propre processus
  sandboxé géré par le système — le type de hasard cross-thread corrigé sur
  `formatFilesize` (buffer `static`) ne peut plus se reproduire de cette façon.

## Plan de test

- **Build/manuel** : build de l'app hôte + 2 extensions, Quick Look sur
  `test.csv`/`testHeight.csv`/`testWidth.csv`/`testMini.csv` (tri des colonnes,
  redimensionnement, miniature avec badge).
- **Automatisé** : ajout d'un nouveau target de test avec le framework
  **Testing**, couvrant :
  - `CSVDocument` (legacy, inchangé) : guillemets/échappement, auto-détection
    de séparateur, cap `maxRows`.
  - `CSVStreamParser` (nouveau) : mêmes cas, plus les cas spécifiques au
    streaming — UTF-16LE/BE avec caractères produisant un octet ambigu,
    cellule dépassant le plafond mémoire, dépassement de `maxColumns`.
  - **Conformité croisée** : sur les fixtures existantes, `CSVStreamParser`
    doit produire les mêmes lignes/colonnes que `CSVDocument` — garde-fou
    contre la divergence entre les deux implémentations de la grammaire CSV
    (voir streaming).

## Hors périmètre

- Suppression du target legacy `.qlgenerator` (PR séparée ultérieure).
- Réécriture de la miniature en SwiftUI/`ImageRenderer` (pas de bénéfice
  identifié par rapport au Core Graphics existant).
- Toute nouvelle fonctionnalité utilisateur au-delà de la parité avec le
  comportement actuel (tri de colonnes mis à part, qui est un bénéfice gratuit
  du composant `Table` natif).
