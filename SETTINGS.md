# Clipsie settings (`config.json`)

All settings live in one file: menu bar icon → Configuration → **Edit Settings…** opens it (it's `~/Library/Application Support/Clipsie/config.json`). After saving, choose menu bar icon → **Reload Settings & Commands**; no restart is needed.

- Clipsie writes the file with every default on first start. You can delete any key: a missing key uses its default, so a small file with only your changes works too.
- If the file isn't valid JSON, Clipsie says so and runs with all defaults until you fix it.
- Commands, generators and sequences are not here: they live in `commands.json` (see the [README](README.md#commands)).

**Shortcut format.** Shortcuts are written like `cmd+shift+v`: modifiers `cmd`, `shift`, `alt` (or `opt`), `ctrl`, joined with `+`, and one key: a letter, digit, `space`, `tab`, `enter`, `esc`, `delete`, `left`/`right`/`up`/`down`, `f1`…`f12`, or one of ``- = [ ] ; ' , . / \ ` ``. An empty string `""` turns the shortcut off.

**App identifiers.** Per-app settings use bundle identifiers such as `com.apple.Safari`. To find one: `osascript -e 'id of app "Safari"'`. Where noted, a key is a **prefix**: `com.jetbrains.` matches every JetBrains IDE, and the longest matching prefix wins.

## Contents

- [Global shortcuts](#global-shortcuts)
- [History and capturing](#history-and-capturing)
- [Privacy](#privacy)
- [Search](#search)
- [The history window](#the-history-window)
- [Commands, generators and sequences](#commands-generators-and-sequences)
- [Plugins](#plugins)
- [Pasting](#pasting)
- [Per-app behaviour](#per-app-behaviour)
- [Text recognition (OCR)](#text-recognition-ocr)
- [Web search buttons](#web-search-buttons)
- [Example](#example)

## Global shortcuts

These work in every app.

| Key | Default | What it does |
|---|---|---|
| `historyHotkey` | `"cmd+shift+v"` | Opens the history window. Required: if it can't be registered, Clipsie shows an error. |
| `pastePlainHotkey` | `"cmd+alt+shift+v"` | Pastes the current clipboard as plain text, without formatting. `""` turns it off. |
| `ignoreNextCopyHotkey` | `""` (off) | Same as menu bar icon → **Ignore Next Copy**: the next thing you copy isn't recorded. The menu bar icon changes to an eye with a slash until then; press again to cancel. |

Commands can have their own global shortcut with `"globalShortcut"` in `commands.json`.

## History and capturing

| Key | Default | What it does |
|---|---|---|
| `maxItems` | `50000` | How many items History keeps. Older ones are deleted when it's full; pinned items are never deleted, and tagged items stay in the Tagged list. |
| `maxItemBytes` | `52428800` (50 MB) | Copies bigger than this (all formats together) aren't recorded or imported. |
| `saveText` | `true` | Record copied text (plain and formatted). |
| `saveImages` | `true` | Record copied images. |
| `saveFiles` | `true` | Record copied files (their paths). |
| `pollInterval` | `0.3` | How often, in seconds, Clipsie checks the clipboard for a new copy. Lower is snappier, higher uses a little less energy. |
| `mergeCopiesWithinMsByApp` | `{"com.jetbrains.": 1000}` | Per app (prefix): copies of the same, growing text within this many milliseconds become one item instead of several. Fixes apps that copy in steps, like JetBrains terminals. Only apps listed here get this behaviour. |
| `clearHistoryOnQuit` | `false` | Delete everything when Clipsie quits, except items with a tag from `keepTagsOnQuit`. Also toggled by menu bar icon → **Clear on Quit**. |
| `keepTagsOnQuit` | `["important"]` | Tags that protect items from `clearHistoryOnQuit`. |

## Privacy

| Key | Default | What it does |
|---|---|---|
| `ignoredApps` | 1Password, 1Password 7, Bitwarden, Keychain Access | Copies made while one of these apps is in front are never recorded. Exact bundle identifiers, not prefixes. Copies that password managers mark as concealed or transient are skipped no matter what. |
| `redact` | `[]` | Extra words and patterns for the **Paste with secrets redacted** command, on top of its built-in rules. A plain word matches whole words, ignoring case; `/…/` is a regular expression; `{"match": …, "with": …}` sets the placeholder (default `[REDACTED]`). An invalid pattern stops the command instead of pasting unredacted text. |
| `linkPreviews` | `false` | When `true`, selecting a link fetches the page title for the preview. This is the only setting that makes Clipsie load something on its own. |

```json
"redact": ["Acme", "/PROJ-\\d+/", {"match": "Project Falcon", "with": "[project]"}]
```

`config.json` isn't encrypted (the history is), so words you list in `redact` are stored as plain text.

## Search

| Key | Default | What it does |
|---|---|---|
| `searchMode` | `"exact"` | `"exact"`: every word must appear. `"fuzzy"`: tolerates typos in longer words. `"regex"`: the whole search is one regular expression. Also switchable by clicking the magnifying glass. Filters like `tag:` and `app:` work in every mode. |

## The history window

| Key | Default | What it does |
|---|---|---|
| `showPreview` | `true` | Show the preview pane next to the list. |
| `menuItemCount` | `20` | How many recent items the menu bar icon's menu lists. |
| `quickPasteModifiers` | `"cmd"` | Modifiers for pasting row 1…9 with a digit (⌘1 … ⌘9). Several are written like `"ctrl+alt"`. `""` turns quick paste off. |
| `moveItemModifiers` | `"cmd"` | Modifiers to hold while dragging to reorder items and palette commands. `""` turns reordering off. |
| `multiPasteSeparator` | `"\n"` | Put between items when several are pasted together, and the default `"separator"` for commands run on several items. |

## Commands, generators and sequences

| Key | Default | What it does |
|---|---|---|
| `commandsPrefix` | `">"` | Typing this in the search opens the commands palette for the selected items. |
| `generatorsPrefix` | `">>"` | Opens the generators palette (UUIDs, passwords, timestamps…). |
| `sequencesPrefix` | `">>>"` | Opens the sequences palette. `""` turns sequences off in the window. |
| `commandsShortcut` | `"cmd+k"` | Key for the commands palette inside the window. Must include `cmd` or `ctrl`; `""` for none. |
| `generatorsShortcut` | `"cmd+shift+e"` | Key for the generators palette inside the window. Same rules. |
| `repeatCommandShortcut` | `"cmd+r"` | Runs the last command again on the selected items. Same rules. |
| `sequenceStepDelayMs` | `100` | Pause between the steps of a sequence, in milliseconds. Raise it if the target app misses keys. |

When a prefix is the start of another (`>` and `>>`), the longest one wins.

## Plugins

| Key | Default | What it does |
|---|---|---|
| `activePlugins` | `["calc.js"]` | Which files from the `plugins` folder run. A plugin that isn't listed here never runs, even if it's in the folder; remove `"calc.js"` to turn the calculator off. |

How to write plugins: see [Plugins in the README](README.md#plugins).

## Pasting

| Key | Default | What it does |
|---|---|---|
| `pasteDelayMs` | `50` | Wait before Clipsie presses ⌘V in the target app, in milliseconds. |
| `pasteDelayMsByApp` | `{"com.jetbrains.": 250, "com.google.android.studio": 250}` | The same wait per app (prefix), for apps that need longer to come to the front. |
| `pasteShortcutByApp` | `{}` | The key Clipsie presses to paste, per app (prefix), for apps or keyboard setups where it isn't ⌘V, e.g. `{"com.jetbrains.": "ctrl+v"}` with Karabiner remapping. |
| `plainTextApps` | `[]` | Apps (prefix) that always get formatted text as plain text, e.g. terminals: `["com.apple.Terminal", "com.googlecode.iterm2"]`. |

## Per-app behaviour

Summary of the settings that take app identifiers:

| Key | Matching |
|---|---|
| `ignoredApps` | exact |
| `plainTextApps` | prefix |
| `pasteDelayMsByApp` | prefix, longest wins |
| `pasteShortcutByApp` | prefix, longest wins |
| `mergeCopiesWithinMsByApp` | prefix, longest wins |

## Text recognition (OCR)

| Key | Default | What it does |
|---|---|---|
| `ocr` | `true` | Recognize text in copied images on your Mac, so screenshots are searchable and ⇧↩ pastes their text. |
| `ocrLanguages` | `[]` | Languages to recognize, as codes like `["en-US", "de-DE"]`. Empty lets macOS choose. Listing your languages helps with accents and non-Latin scripts. |

## Web search buttons

`searchProviders` sets the buttons shown when you hover over a text preview. Each opens your browser with the selected text. Default: Google, Google AI Mode, ChatGPT and Claude.

| Field | What it does |
|---|---|
| `name` | Shown in the button's tooltip ("Search with …"). |
| `url` | The address to open; `{q}` is replaced with the text (shortened to 2,000 characters). |
| `symbol` | Optional SF Symbol name for the button, e.g. `"magnifyingglass"`. |
| `icon` | Optional address of an image to use as the button. |
| `favicon` | Optional, default `true`: load the site's own icon from the `url`'s host. `false` keeps the `symbol`. |

```json
"searchProviders": [
  {"name": "DuckDuckGo", "url": "https://duckduckgo.com/?q={q}", "symbol": "magnifyingglass"},
  {"name": "Wikipedia", "url": "https://en.wikipedia.org/w/index.php?search={q}", "favicon": false, "symbol": "book"}
]
```

Loading favicons is a network request to each site; set `"favicon": false` to avoid it. `[]` removes all buttons.

## Example

A small file that only changes what it needs; everything else keeps its default:

```json
{
  "historyHotkey": "cmd+shift+v",
  "ignoreNextCopyHotkey": "cmd+alt+shift+i",
  "maxItems": 10000,
  "searchMode": "fuzzy",
  "plainTextApps": ["com.apple.Terminal", "com.googlecode.iterm2"],
  "ignoredApps": ["com.1password.1password", "com.bitwarden.desktop", "com.apple.keychainaccess"],
  "redact": ["Acme", "/PROJ-\\d+/"],
  "clearHistoryOnQuit": true,
  "keepTagsOnQuit": ["important", "keep"]
}
```

Note that a list you set replaces the default list: the `ignoredApps` above no longer includes 1Password 7, so add back what you still need.
