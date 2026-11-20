# Development notes

The README is the page a stranger reads once. This file carries the rest.

## Files

| Path | Role |
|---|---|
| `manifest.json` | Plugin manifest, `bar-widget` kind, entry point `BarWidget.qml` |
| `BarWidget.qml` | Bar glyph, panel host, IPC routes, selection reader |
| `Panel.qml` | Popup: input, translation, settings, language picker, history |
| `Model.js` | Request building, reply parsing, language and history helpers |
| `install.sh` | Copies the files into the plugin directory and places the widget |
| `scripts/test-model.js` | Execution test for `Model.js`, 54 assertions |

`Panel.qml` is loaded by `BarWidget.qml` through a `Loader`, so the manifest
declares one kind, not two.

## Models

`model` answers first. `fallbackModel` answers when the first one refuses or
returns empty text. Both are plain strings in `config.json`.

The prompt follows the model id, not a setting:

1. A translation model (`*-translate-*`) gets the language pair as its system
   message, for example `de-ru`.
2. Any other chat model gets a sentence that names the target language.

German needs an article. A chat model is told that a short noun phrase takes its
definite article and a capital letter: `Linie` → `Die Linie`. A translation
model cannot be asked for that, so for an input of three words or fewer the chat
model goes first and the translation model is the retry. Longer input keeps the
configured order.

Thinking is off in every request: `chat_template_kwargs: {enable_thinking: false}`.
A reasoning model otherwise spends seconds before the translation starts, and
the trace can fill `max_tokens` before any translation is written.

## Source language

The source language is not left to the model:

1. Cyrillic means Russian.
2. Umlauts, or two German function words, mean German.
3. Anything else counts as English.

If the detected source equals the target, the pair flips: Russian text goes to
German, everything else to Russian.

A stress mark over a Cyrillic vowel is a reading aid, not a letter. It is
stripped from the input, because it misleads both the model and the word count.

## Where the text comes from

Opening the popup is the hotkey's route. The panel reads the primary selection
itself with `wl-paste --primary`, and acts on it only when it differs from what
is already shown. A click on the bar glyph and the hotkey therefore do the same
thing, and no IPC route into the plugin is required.

`translate` is a plain function on the widget, not an IPC route: a third-party
plugin's own `ShellIpc` target is not reachable from the CLI on this shell, so
the panel is reached through the host route `omarchy-shell shell toggle
L1-translator`. The widget exposes no route of its own, and none that reads the
selection.

## Tests

```sh
node scripts/test-model.js
```

The suite loads `Model.js`, drops the QML-only `.pragma` line, and asserts on
the pure functions: the language table and its search, the short-phrase test,
stress stripping, the model order, the request bodies for both prompt styles,
reply parsing including the error paths, and the history helpers. It needs
nothing but Node.

## Verification limits

Two layers run anywhere: this suite, and `omarchy plugin validate <folder>` from
the Omarchy installation itself.

`qmllint` is the third layer and it needs the running shell:

```sh
qmllint -I "$OMARCHY_PATH/shell" ~/.config/omarchy/plugins/L1-translator/BarWidget.qml \
  ~/.config/omarchy/plugins/L1-translator/Panel.qml
```

Without `$OMARCHY_PATH/shell` the tool cannot resolve `qs.Ui`, `qs.Commons` or
Quickshell, so it reports syntax only. Runtime behaviour is observable on an
Omarchy machine alone.

## Security

- `config.json` holds the token. It stays outside this repository.
  `install.sh` creates the plugin directory with mode 700 and that file with
  mode 600 from creation, so no window exists at a looser mode.
- The settings screen writes the file in-process, never through a command line:
  a payload in argv is readable in `/proc` for the life of the process, and
  this one carries the key. A chmod follows the write as a second line.
- The reply is untrusted text from a third-party endpoint: it is cut at 8000
  characters before it reaches layout, the clipboard or the history file, and a
  provider error message is cut at 200.
- The request times out after 20 s. A newer translation aborts the request in
  flight, and closing the popup cancels it.
- The primary selection and the clipboard are read through
  `wl-paste | head -c 8192`: the cap applies in the pipe.
- The plugin exposes one IPC route, `translate <text>`, which takes its text
  from the caller. No route reads the user's selection, so a local process
  cannot make the widget pull what is highlighted and send it out.
- `install.sh` copies files and calls Omarchy commands. It starts no service
  and asks for no privilege beyond the user's own. A removal that fails reports
  the failure instead of printing success.

### Limits that stay

- The response body is buffered whole by the QML `XMLHttpRequest` before the
  character cap applies; only a streaming client or a proxy can bound it
  earlier.
- Qt follows redirects for this request and QML cannot set a redirect policy,
  so a 30x answered by the configured endpoint sends the request, header
  included, to wherever it points. Use an `https` endpoint you trust.

## Update

`git pull`, then `bash start.sh` again. The installer overwrites the QML and
leaves `config.json` untouched.

## Remove

```sh
bash start.sh --uninstall
```

That calls `omarchy plugin disable L1-translator`, `omarchy plugin remove
L1-translator` and rescans the plugins. `config.json` and the history file stay
in place; delete them by hand if you want them gone.
