import AppKit

enum Help {
    static func text(commands: String, generators: String, sequences: String, quickPaste: String?, move: String?,
                     repeatCommand: String?) -> NSAttributedString {
        let result = NSMutableAttributedString()
        func heading(_ text: String) {
            result.append(NSAttributedString(string: (result.length == 0 ? "" : "\n") + L(text) + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.labelColor,
            ]))
        }
        func row(_ key: String, _ description: String) {
            let style = NSMutableParagraphStyle()
            style.tabStops = [NSTextTab(textAlignment: .left, location: 190)]
            style.headIndent = 190
            style.paragraphSpacing = 3
            result.append(NSAttributedString(string: key + "\t", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
            ]))
            result.append(NSAttributedString(string: L(description) + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
            ]))
        }
        func note(_ text: String) {
            result.append(NSAttributedString(string: L(text) + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor,
            ]))
        }
        func code(_ text: String) {
            result.append(NSAttributedString(string: text + "\n", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.labelColor,
            ]))
        }

        heading("Search")
        note("All words must match the item's text or title. Mix in filters, in any order:")
        row("tag:work", "items tagged work (the start is enough: tag:wo)")
        row("app:slack", "copied from an app (bundle id or name)")
        row("type:link", "text, rich, image, file, link, color, other")
        row("is:pinned", "also is:tagged, is:titled")
        row("date:today", "also yesterday, week, month, 2026-10-20")
        row("after:2026-10-01", "and before:2026-10-15")
        row("invoice app:mail tag:work", "example")
        note("Click the magnifying glass to switch the search mode: exact (default), fuzzy (tolerates typos) or regex (the text is one regular expression).")

        heading("Keys")
        row("↩  ⇧↩", "paste · paste as plain text (an image: the text in it)")
        if let quickPaste { row("\(quickPaste)1 … \(quickPaste)9", "paste row 1…9") }
        if let move { row("\(move)-drag", "move an item in any list (pinned items: their order), or a command in a palette: dragged ones stay on top") }
        row("``` or ~~~", "typed quickly: paste the selected item as a code block")
        row("⇧↑ ⇧↓  ⌘-click", "select several; ↩ pastes them in the order selected")
        row("⌘C", "copy without pasting")
        row("⌘I", "add or remove the tag “important”")
        row("⌘L", "edit tags (also the tag button below the preview)")
        row("⌘E", "title, shown instead of the content")
        row("⌘P", "pin (stays on top, never pruned)")
        row("⌘↩", "edit the text; ⌘S saves, Esc cancels")
        row("⌘⌫", "delete from History (in Tagged: remove the tags)")
        row("⌘Y", "Quick Look copied files")
        row("⇥  ⇧⇥", "History · Images · Tagged")
        row(commands, "commands for the selected item")
        row(generators, "generators (UUID, timestamp, password…)")
        row("→  ←", "commands · generators · sequences, with the cursor at the end (← at the start) of the search")
        if let repeatCommand { row(repeatCommand, "run the last command again") }
        row("⌥↩", "in the commands palette: keep a command on for every paste, shown as a pill at the bottom of the window; click the pill to turn it off")
        row("Esc", "clear the search, then close")
        note("Type 3 or more letters of a generator's name to get it on top of the search results. The palettes list your most used commands first, and initials work too: pu finds Paste UPPERCASE.")

        heading("Tags")
        note("Tagged items are listed in Tagged and kept there when they leave History (pruning, delete, Clear History). "
            + "The tag “important” exists from the start. Click a tag below the preview to search for it.")

        heading("Commands — commands.json (menu bar → Configuration → Edit Commands…)")
        note("A command is a line of JavaScript, run sandboxed. It gets the item's text as `text` and returns the result. "
            + "Longer scripts need `return`. After editing: menu bar → Reload Settings & Commands.")
        code(#"{"name": "UUID without dashes", "input": "none", "script": "clip.uuid().replaceAll('-', '')", "output": "paste"}"#)
        code(#"{"name": "Quote lines", "script": "text.split('\\n').map(l => '\"' + l.replaceAll('\"', '\\\\\"') + '\"').join('\\n')", "output": "paste"}"#)
        code(#"{"name": "Sort lines", "script": "text.split('\\n').sort().join('\\n')", "output": "replace", "shortcut": "cmd+shift+s"}"#)
        code(#"{"name": "Trim what I copy", "type": "automatic", "script": "text.trim()", "output": "replace"}"#)
        note("replace('-', '') changes only the first match: use replaceAll, or a regex with g like /-/g. "
            + "In JSON, a \\n meant for JavaScript is written \\\\n.")
        row("output", "paste, copy, newItem, replace (the item), none")
        row("input", "item (default) or none (generators)")
        row("match", "regex the item's text must match")
        row("type", "menu (default) or automatic: runs on every copy; return false to not save it")
        row("shortcut", "key in this window; globalShortcut works anywhere")
        row("clip.uuid()", "also clip.randomHex(n), clip.randomBase64(n)")
        row("clip.hash('sha256', text)", "md5, sha1, sha256, sha384, sha512")
        row("clip.base64Encode(text)", "and clip.base64Decode(text)")
        row("clip.history(10)", "texts of the 10 latest items")
        row("clip.log(…)", "to Console.app; item.sourceApp, item.types are there too")

        row("types", "text, rich, image, file, link, color, other; default: items with text or files")

        heading("Images")
        note("Image items come with item.image (width, height). Return an image and the output (paste, copy, newItem, replace) is an image too. Built-in: resize, rotate, flip, grayscale, convert, copy as data URL.")
        code(#"{"name": "Thumbnail", "types": ["image"], "script": "clip.image.resize(item.image, { max: 256 })", "output": "paste"}"#)
        row("clip.image.resize(img, {…})", "width, height, max (longest side) or scale")
        row("clip.image.crop(img, {…})", "x, y (from the top left), width, height")
        row("clip.image.rotate(img, 90)", "clockwise, in steps of 90°; flip(img, \"vertical\")")
        row("clip.image.convert(img, \"jpeg\")", "png, jpeg, heic, tiff; { quality: 0.8 }")
        row("clip.image.toDataURL(img)", "text like data:image/png;base64,…; also grayscale(img)")

        heading("Sequences")
        note("Select items (⌘-click or ⇧↓) and choose Save as Sequence… in the right-click menu. A sequence pastes item 1…n of your selection with keys and pauses in between, e.g. to fill a form. It's a command in commands.json:")
        code(#"{"name": "Fill login form", "sequence": "item 1, tab, item 2, enter"}"#)
        row("item 1", "the 1st selected item (in the order you selected)")
        row("\"text\"", "this text")
        row("wait 200", "pause 200 ms (also 0.5s)")
        row("tab, enter, cmd+a", "press a key")
        note(L("Run sequences with %@ or the right-click menu. With fewer items selected than a sequence uses, it stops at the first missing item.", sequences))
        note("Commands on several items: \"multiple\": \"each\" runs once per item (default), \"all\" once on all texts joined with \"separator\".")

        heading("Plugins — plugins/ in the data folder")
        note("A .js file gets the search text as `text` and returns a string or { value, title }; its row is shown on top. "
            + "The built-in calculator: 3 plus 4, 15% of 80, 2^10, 5 km in miles, 100 f to c.")
        note("Only plugins listed in activePlugins in config.json run; the default is [\"calc.js\"].")

        heading("Files — menu bar → Configuration → Open Data Folder")
        note("config.json (settings), commands.json, plugins/, scripts/ (for \"scriptFile\"). The history itself is encrypted.")
        return result
    }
}
