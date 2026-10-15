# Écritoire

*[Version française](README.md)*

Écritoire is a word processor for macOS, designed for long texts. You write in a **binder** (*classeur*),
which is simply a folder of Markdown files: your texts stay readable by any other software, and you can sync,
version or review them with the tools of your choice.

The interface is in French.

![The binder and the editor](docs/captures/classeur.png)

## What Écritoire does

- **A text editor, not a code editor**: Markdown signs (`**`, `#`, `>`) disappear and the text is laid out
  as on a page. They reappear, dimmed, only in the paragraph where the cursor is.
- **The binder**: a tree of folders and documents, manual order by drag and drop, icons, a document outline,
  and a search across the whole binder (⇧⌘F) that ignores accents.
- **Writing**: focus mode, typewriter scrolling, zoom, an inspector (title, synopsis, status).
- **Reviewing**: comments anchored in the text, snapshots and a changes view (accept or reject each change),
  coloured highlighters.
- **Poems**: one verse per paragraph, verse numbers in the margin, automatic renumbering, “v. 12” references.
- **Export**: clean Markdown, or an A4 PDF faithful to the page (Fichier → Exporter…, ⇧⌘E). A whole folder
  becomes a single file.
- **Scrivener import**: a `.scriv` project becomes a binder; the original is never modified.

![A poem in poem display](docs/captures/poeme.png)

<img src="docs/captures/export-pdf.png" alt="The same poem exported to PDF" width="420">

## Building the app

You need macOS 14 or later and Apple's command line developer tools (`xcode-select --install`).
Xcode is not required.

```sh
git clone <repository address> Ecritoire
cd Ecritoire
./scripts/construire-app.sh              # builds Ecritoire.app in this folder
open Ecritoire.app
./scripts/construire-app.sh --installer  # or: copies the app to ~/Applications
```

For development: `swift run Ecritoire --classeur "Classeur d'exemple"`.
Checks: `swift build && swift run EcritoireVerifs`.

Without Xcode there are two constraints: no SwiftUI `@State`, and no XCTest or Swift Testing (their macros only
ship with Xcode). The checks are therefore an executable, `EcritoireVerifs`.

## Updates

The app checks once a day for a new version (menu **Écritoire → Rechercher les mises à jour…**), downloads it and
installs it by itself, thanks to [Sparkle](https://sparkle-project.org) (MIT licence). Versions are published as
[GitHub releases](https://github.com/brunmul/ecritoire/releases), signed with EdDSA.

The app is not signed by Apple: the first time you open a downloaded version, right-click it → Open
(on macOS 15 and later: System Settings → Privacy & Security → “Open Anyway”).

Publishing a version (maintainer): `./scripts/publier-version.sh 0.2`. The private signing key stays in the
maintainer's Mac keychain, never in the repository.

## Fonts

Écritoire uses **Walbaum** and **Walbaum Grotesk** when they are installed on the Mac. They are commercial
fonts and are never distributed with the software. Otherwise Écritoire uses two free fonts bundled with the
app, [Libre Bodoni](https://github.com/google/fonts/tree/main/ofl/librebodoni) and
[Hanken Grotesk](https://github.com/google/fonts/tree/main/ofl/hankengrotesk), under the SIL Open Font License
(files and licences in `Resources/Polices`).

## Importing a Scrivener project

In the app: **Fichier → Importer un projet Scrivener…** (⇧⌘I). From the command line, for several projects:

```sh
swift run -c release importer-scrivener MyProjects/*.scriv             # → ~/Documents/Classeurs
swift run -c release importer-scrivener project.scriv --vers ~/other/folder
```

The original project is never modified. Kept: the tree and its order, titles, bold, italic, lists, links,
quotes and section headings (from Scrivener styles), images (copied next to the document), synopsis, status,
label, keywords, notes (as a `%% … %%` comment) and dates. The trash is not imported. Not kept: Scrivener
footnotes and comments, tables (plain text), snapshots, page layout.

## Binder format

- A binder folder is a folder; a document is a `.md` file. Other files are ignored.
- Manual order: a `.order` file in each folder, one name per line.
- A YAML header in each document (keys compatible with Quartz); other keys are kept as they are:

  ```yaml
  ---
  title: "Le départ"
  synopsis: "Élise quitte la ville à l'aube."
  status: "brouillon"     # idée, brouillon, en cours, relu, terminé
  publish: false
  ---
  ```

- What is not text (comments, snapshots, poem or prose display) is stored in a `.ecritoire` folder at the root
  of the binder, never in the Markdown files.

Documents are saved automatically 0.8 s after the last keystroke, and on quit. If an open document is changed
by another program, it is reloaded; if there is a conflict, a banner lets you choose.

## Keyboard shortcuts

| | |
|---|---|
| ⌘N / ⇧⌘N | New document / folder |
| ⌘O | Open a binder |
| ⇧⌘E | Export (Markdown or PDF) |
| ⇧⌘F | Search the binder or all binders |
| ⇧⌘↩ | Focus mode (Esc to leave) |
| ⌥⌘T | Typewriter scrolling |
| ⌥⌘I | Inspector |
| ⌥⌘M / ⌥⌘C | Comment the selection / show comments |
| ⌥⌘R | Show changes since the snapshot |
| ⌥⌘0 to ⌥⌘6 | Paragraph styles |
| ⌘+ / ⌘− / ⌘0 | Text size |

## Code layout

- `Sources/EcritoireCore`: logic without interface (YAML header, binder and `.order`, comments, poems,
  search, Markdown export, disk watching).
- `Sources/Ecritoire`: the application (SwiftUI and AppKit, NSTextView TextKit 2 editor, PDF export).
- `Sources/ScrivenerImport` and `Sources/ImporterScrivener`: the Scrivener import.
- `Sources/EcritoireVerifs`: the checks.
- No external dependencies.

## Licence

Écritoire is free software, released under the GNU General Public License, version 3 or (at your option) any
later version: see [LICENSE](LICENSE). The fonts in `Resources/Polices` keep their own licence
(SIL Open Font License).
