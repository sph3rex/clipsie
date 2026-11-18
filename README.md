<p align="center">
  <img src="clipsie-header.png" width="100%" alt="Clipsie, a crocodile peeking over a paper clip">
</p>

<h1 align="center">Clipsie</h1>

<p align="center">
  A fast, private clipboard history for macOS, with a Spotlight-style window, tags and JavaScript commands.
</p>

---

Clipsie lives in the menu bar and remembers everything you copy: text, formatted text, images, files. Press <kbd>⌘</kbd><kbd>⇧</kbd><kbd>V</kbd>, type a few letters, press <kbd>↩</kbd>, and it is pasted into the app you were in, exactly as it was copied.

## Features

- **Everything you copy, exactly.** Every format of every copy is kept, so pasting into Word, Figma, Finder or a terminal behaves like the original copy. <kbd>⇧</kbd><kbd>↩</kbd> pastes as plain text.
- **Instant search** over tens of thousands of items, with filters: `app:slack`, `type:image`, `type:link`, `date:week`, `tag:work`, `is:pinned`.
- **Tags** to keep and group things: tagged items stay in the Tagged list when they leave the history. <kbd>⌘</kbd><kbd>I</kbd> toggles the built-in `important` tag.
- **Rich previews:** images, files (with Quick Look), colors with their hex/rgb/hsl values, highlighted JSON, links with a clickable title.
- **Text in images:** screenshots are searchable by the text in them (recognized on your Mac).
- **Commands in JavaScript,** run sandboxed: transform an item (trim, change case, hash, Base64, JSON…) or generate something (UUID, password, timestamp), and add your own in a few lines.
- **Calculator and unit converter** in the search: `15% of 80`, `5 km in miles`, `100 f to c`.
- **In your language:** English, German, French, Spanish, Romanian, Chinese (Simplified) and Japanese, following your macOS language (or per app: System Settings → General → Language & Region → Applications). Search filters and calculator words stay English.
- **Private by design:** the history is encrypted on disk, passwords from password managers are never recorded, and nothing leaves your Mac.

## Install

Requires macOS 13 Ventura or later, on Apple Silicon or Intel.

```bash
brew tap sph3rex/clipsie https://github.com/sph3rex/clipsie
brew install --cask clipsie
```

Then open Clipsie from Applications. On first launch:

1. **Allow Accessibility** when macOS asks (System Settings → Privacy & Security → Accessibility). Clipsie needs it to paste for you by sending <kbd>⌘</kbd><kbd>V</kbd>; without it, choosing an item only puts it on the clipboard.
2. If macOS asks whether Clipsie may use **"Clipsie history key"** from your Keychain, choose **Always Allow**. That is the key that decrypts your history.
3. Optional: menu bar icon → **Launch at Login**.

Update with `brew upgrade --cask clipsie`. Clipsie isn't signed with an Apple Developer ID, so after an update macOS may ask for the Accessibility permission and the Keychain again.

<details>
<summary>Build from source instead</summary>

Needs the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/sph3rex/clipsie.git
cd clipsie
./build.sh install    # builds Clipsie.app, copies it to /Applications and starts it
```

</details>

## Using it

Press <kbd>⌘</kbd><kbd>⇧</kbd><kbd>V</kbd> anywhere (or click the menu bar icon). Start typing to search; all words must match. Click the magnifying glass to switch between exact, fuzzy (typo-tolerant) and regular-expression search. The preview on the right shows the selected item.

| Key | Does |
|---|---|
| <kbd>↩</kbd> / <kbd>⇧</kbd><kbd>↩</kbd> | paste / paste as plain text |
| <kbd>⌘</kbd><kbd>1</kbd> … <kbd>⌘</kbd><kbd>9</kbd> | paste item 1…9 |
| <kbd>⌘</kbd><kbd>C</kbd> | copy without pasting |
| <kbd>⇧</kbd><kbd>↑</kbd> <kbd>⇧</kbd><kbd>↓</kbd>, <kbd>⌘</kbd>-click | select several items; <kbd>↩</kbd> pastes them together, in the order you picked them, and commands run on each of them |
| <kbd>⌘</kbd><kbd>P</kbd> | pin to the top |
| <kbd>⌘</kbd>-drag | move an item in History; for pinned items this sets their order (`moveItemModifiers`) |
| <kbd>⌘</kbd><kbd>I</kbd> / <kbd>⌘</kbd><kbd>L</kbd> | toggle the `important` tag / edit tags |
| <kbd>⌘</kbd><kbd>E</kbd> | give the item a title |
| <kbd>⌘</kbd><kbd>↩</kbd> | edit the item's text |
| <kbd>⌘</kbd><kbd>⌫</kbd> | delete |
| <kbd>⌘</kbd><kbd>Y</kbd> | Quick Look copied files |
| <kbd>⇥</kbd> | switch between History, Images and Tagged |
| <kbd>⌘</kbd><kbd>K</kbd> or `>` | commands for the selected item |
| <kbd>⌘</kbd><kbd>⇧</kbd><kbd>E</kbd> or `>>` | generators (UUID, password, timestamp…) |
| `` ``` `` typed quickly | paste the item as a Markdown code block |
| `??` typed quickly | help: all keys, search filters and script examples |
| <kbd>Esc</kbd> | clear the search, then close |

Anywhere, <kbd>⌘</kbd><kbd>⌥</kbd><kbd>⇧</kbd><kbd>V</kbd> pastes what is on the clipboard as plain text.

### Search filters

Mix them with normal words, in any order: `invoice app:mail date:week`.

| Filter | Finds |
|---|---|
| `tag:work` | items tagged work (the start of the name is enough) |
| `app:slack` | items copied from an app |
| `type:text` `rich` `image` `file` `link` `color` | that kind of item |
| `is:pinned` `is:tagged` `is:titled` | pinned, tagged or titled items |
| `date:today` `yesterday` `week` `month` `2026-10-20` | items last used then |
| `after:2026-10-01` `before:2026-10-15` | items last used in a range |

## Commands

Commands live in `commands.json` (menu bar icon → Configuration → Edit Commands…) and are a line of JavaScript that gets the item's text as `text`:

```json
{"name": "Sort lines", "script": "text.split('\\n').sort().join('\\n')", "output": "paste", "shortcut": "cmd+shift+s"}
{"name": "UUID without dashes", "input": "none", "script": "clip.uuid().replaceAll('-', '')", "output": "paste"}
```

Scripts run sandboxed inside Clipsie: no files, no network, only a small `clip` helper API (hashes, Base64, UUIDs, random values, recent items). Automatic commands run on every copy, e.g. to skip one-time codes or strip tracking parameters from links. Search plugins work the same way and add rows to the results, like the built-in calculator. Type `??` in the history window for more examples, the main command options and the whole `clip` API.

With several items selected, a command runs once per item and the results are joined (`"multiple": "each"`, the default), or once on all their texts joined together (`"multiple": "all"`). Either way, `"separator"` sets what goes between them.

`"types"` limits a command to kinds of items: `text`, `rich`, `image`, `file`, `link`, `color`, `other`. Without it, a command applies to items that have text or files.

## Images

Commands can work on images too. An image item gives the script `item.image`; when the script returns an image, the result (`paste`, `copy`, `newItem`, `replace`) is an image again. Clipsie has built-in image actions in the commands (<kbd>⌘</kbd><kbd>K</kbd>, right-click): resize to 50 % or to fit 1024 px, rotate left/right, flip, grayscale, convert to JPEG or PNG, and copy as a data URL.

```json
{"name": "Thumbnail", "types": ["image"], "script": "clip.image.resize(item.image, { max: 256 })", "output": "paste"}
```

| Function | Does |
|---|---|
| `clip.image.resize(img, { width, height, max, scale })` | resizes; one side keeps the aspect ratio, `max` fits the longest side |
| `clip.image.crop(img, { x, y, width, height })` | crops; `x`/`y` from the top left |
| `clip.image.rotate(img, 90)` | turns clockwise in steps of 90° |
| `clip.image.flip(img, "horizontal")` | mirrors (`"vertical"` too) |
| `clip.image.grayscale(img)` | removes the colour |
| `clip.image.convert(img, "jpeg", { quality: 0.8 })` | sets the output format: `png`, `jpeg`, `heic`, `tiff` |
| `clip.image.toDataURL(img)` | returns `data:image/png;base64,…` as text |

Images are processed in memory and never written to disk; sides are limited to 16,384 pixels. To hide a built-in action, add `{"name": "Rotate image left", "enabled": false}` to `commands.json`; a command of yours with the same name replaces it.

## Sequences

A sequence pastes several items one after another, with keys and pauses in between: handy for filling the same form again and again. Select the items in the order you want (<kbd>⌘</kbd>-click or <kbd>⇧</kbd><kbd>↓</kbd>), right-click and choose **Save as Sequence…**. From then on it shows up in the commands (<kbd>⌘</kbd><kbd>K</kbd> or `>`) whenever enough items are selected.

```json
{"name": "Fill login form", "sequence": "item 1, tab, item 2, enter"}
```

| Step | Does |
|---|---|
| `item 1` … `item 9` | pastes the 1st…9th selected item, in the order you selected them |
| `"some text"` | pastes that text |
| `wait 200` | pauses 200 ms (`0.5s` works too) |
| `tab`, `enter`, `shift+tab`, `cmd+a`, `down`, … | presses that key |

Steps are separated by commas or new lines; `sequenceStepDelayMs` in `config.json` (default 100) is the pause between steps. A sequence stops if another app comes to the front while it runs.

## Settings

Menu bar icon → Configuration → Edit Settings… opens `config.json`: shortcuts, history size (50,000 items by default), apps to ignore, apps that always get plain text, what to store (`saveText`, `saveImages`, `saveFiles`), the search mode (`searchMode`: `exact`, `fuzzy` for typo-tolerant search, or `regex`), merging quick successive copies of the same growing text into one entry, for the apps listed in `mergeCopiesWithinMsByApp` (default `{"com.jetbrains.": 1000}`, the time window in ms), deleting everything when Clipsie quits (`clearHistoryOnQuit`, or the menu's Clear on Quit) except items with a tag listed in `keepTagsOnQuit` (default `["important"]`), web-search buttons, and more. Reload with menu bar icon → Reload Settings & Commands. Keys you leave out keep their defaults.

## Privacy

- **Encrypted history.** Items are stored in an SQLite database encrypted with [SQLCipher](https://www.zetetic.net/sqlcipher/) (AES-256); the key is kept in your login Keychain.
- **Skips secrets.** Copies that password managers mark as concealed or transient are never recorded, nor is anything from apps in `ignoredApps`. A default command skips one-time codes.
- **Stays on your Mac.** Clipsie makes no network requests of its own, except to load the icons of the web-search buttons and, only if you turn on `linkPreviews`, the title of a selected link.
- **Sandboxed scripts.** JavaScript commands and plugins can't read files or use the network. Shell commands are possible too, for menu commands only, and are marked ⚠︎ because they are not sandboxed.
- **Export** (menu bar icon → Import & Export → Export as JSON…) writes an unencrypted file, for backups or moving to another Mac; Import reads it back.

## Uninstall

```bash
brew uninstall --cask clipsie           # keeps your history and settings
brew uninstall --zap --cask clipsie     # also deletes them
```

The history and settings are in `~/Library/Application Support/Clipsie`. The Keychain item "Clipsie history key" can be deleted in Keychain Access.

## Translations

The interface is translated in `Resources/<language>.lproj/Localizable.strings`; the English text in the code is the key, and anything not translated shows in English. The names of the default commands are translated when shown, while `commands.json` itself stays English.

```bash
python3 tools/check-translations.py    # lists, per language, strings missing from the translations
```

Translations exist for German, French, Spanish, Romanian, Chinese (Simplified) and Japanese. To add a language, copy one of the files to a new `<code>.lproj` folder, translate the right-hand sides, and add the code to `CFBundleLocalizations` in `Resources/Info.plist`.

## In other languages

**Deutsch** — Clipsie ist ein schneller, privater Zwischenablage-Manager für macOS: ein durchsuchbarer Verlauf der Zwischenablage mit Tags, verschlüsselter Speicherung, Texterkennung in Bildern und JavaScript-Befehlen. Installation mit Homebrew (siehe oben); die Oberfläche ist auf Deutsch.

**Français** — Clipsie est un gestionnaire de presse-papiers rapide et privé pour macOS : un historique du presse-papiers consultable, avec tags, stockage chiffré, reconnaissance du texte dans les images et commandes JavaScript. Installation avec Homebrew (voir plus haut) ; l’interface est en français.

**Español** — Clipsie es un gestor del portapapeles rápido y privado para macOS: un historial del portapapeles con búsqueda, etiquetas, almacenamiento cifrado, reconocimiento de texto en imágenes y comandos JavaScript. Se instala con Homebrew (ver arriba); la interfaz está en español.

**Română** — Clipsie este un manager de clipboard rapid și privat pentru macOS: un istoric al clipboardului cu căutare, etichete, stocare criptată, recunoașterea textului din imagini și comenzi JavaScript. Se instalează cu Homebrew (vezi mai sus); interfața este în română.

**简体中文** — Clipsie 是一款快速、注重隐私的 macOS 剪贴板管理器：可搜索的剪贴板历史记录，支持标签、加密存储、图片文字识别（OCR）和 JavaScript 命令。可通过 Homebrew 安装（见上文）；界面支持简体中文。

**日本語** — Clipsie は macOS 用の高速でプライバシーに配慮したクリップボード管理アプリです。検索できるクリップボード履歴、タグ、暗号化された保存、画像内の文字認識（OCR）、JavaScript コマンドに対応しています。Homebrew でインストールできます（上記参照）。日本語の画面に対応しています。

## License

Clipsie is released under the [MIT License](LICENSE).

It includes [SQLCipher](https://www.zetetic.net/sqlcipher/) by Zetetic LLC, under its BSD-style license ([Sources/CSQLCipher/LICENSE.md](Sources/CSQLCipher/LICENSE.md)), which is built on [SQLite](https://sqlite.org), in the public domain.
