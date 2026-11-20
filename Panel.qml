import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// The translator popup: a target-language row, one input line, the
// translation with a copy icon, and the last translations.
//
// The bar widget owns the glyph and the IPC routes; this panel owns the state
// and the request. It is nested inside the bar-widget plugin, so the manifest
// declares no second kind.
Panel {
  id: root
  moduleName: "L1-translator"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget in its slot, not this nested panel, so every
  // identity the popout coordinator compares has to be the host widget.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  property var config: Model.parseConfig("{}")
  property string configProblem: ""
  property string inputText: ""
  property string outputText: ""
  property string statusLine: ""
  property bool busy: false
  property bool failed: false
  property string targetLang: "ru"
  property var history: []
  // The history list starts folded: the panel opens short, and the header
  // opens the list on a click.
  property bool historyOpen: false
  // True for a moment after a click on the copy icon: the icon shows a check
  // mark instead of the copy glyph.
  property bool copied: false
  // The same answer for the paste icon, which also starts a translation.
  property bool pasted: false
  // The settings section and its language list.
  property bool settingsOpen: false
  property bool languageOpen: false
  property bool showKey: false
  // The settings fields live inside the panel content, which the loaded panel
  // keeps in its own scope: root functions reach them through this signal.
  signal fillLanguage(string value)
  signal fillKey(string value)
  property string languageQuery: ""
  readonly property var languageOptions: Model.findLanguages(root.languageQuery)
  // Ten rows are visible at once. The store keeps Model.HISTORY_LIMIT (20)
  // entries, so the list scrolls through the rest.
  readonly property int historyVisibleRows: 10
  readonly property int historyRowHeight: Math.max(Style.space(20), Math.ceil(Style.font.bodySmall * 1.8))
  property int requestSerial: 0
  // True only between an open and the first text that open receives: it says
  // the panel may read the primary selection itself.
  property bool autoRead: false

  // ---- one layout scale for the whole panel -------------------------------
  // One inset, one row gap, one icon square. Every row below reads these and
  // nothing else, so the four sides of the content box stay equal.
  readonly property int pad: Style.spacing.popupPadding
  readonly property int rowGap: Style.spacing.panelGap
  readonly property int iconSide: Math.ceil(Style.font.subtitle * 1.4)
  // One height for the input field and every icon button beside it: derived
  // from the same tokens the kit's TextField uses, so a button and the field
  // form one strip and no item has to read another item's size.
  readonly property int fieldHeight: Math.ceil(Style.font.subtitle
    + 2 * (Style.spacing.inputPaddingY + Style.normalBorderWidth))
  // Every icon button is this square: the glyph box plus the two-pixel frame
  // that carries the hover state. One size, so the column reads as one column.
  // The icon buttons take their height from the input field, so a button and
  // the field next to it form one strip of equal height.

  readonly property var languages: Model.languages()
  readonly property string tooltipLine: outputText !== "" ? Model.preview(outputText, 70) : ""
  readonly property color contentForeground: root.barForeground
  // Service text: the pair line, the status, the hints, the history. It keeps
  // the foreground colour and drops to 70% instead of turning darker.
  readonly property color dimForeground: Util.alpha(root.barForeground, 0.7)
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int fieldLimit: config.maxChars > 0 ? config.maxChars : 2000

  readonly property string configPath: Quickshell.env("HOME")
    + "/.config/omarchy/plugins/" + root.moduleName + "/config.json"
  readonly property string historyPath: Quickshell.env("HOME")
    + "/.local/state/omarchy/L1-translator-history.json"

  // ---- lifecycle ----------------------------------------------------------

  function open() {
    root.autoRead = true
    root.historyOpen = false
    root.controller.show()
    Qt.callLater(root.focusField)
  }

  function close() {
    Model.cancel()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  // Opening is also the hotkey's route: a highlighted line is translated
  // without any IPC call into this plugin, because the panel reads the
  // primary selection itself. A click therefore does the same thing a hotkey
  // does, and a plugin IPC route is a convenience, not a requirement.
  // A caller that hands text in (`translate`) turns autoRead off first, so
  // its text is never overwritten by whatever happens to be highlighted.
  onOpenedChanged: {
    if (!root.opened) return
    Qt.callLater(root.focusField)
    if (root.autoRead) primaryReader.running = true
  }

  Process {
    id: clipboardReader
    // head bounds what the shell buffers: the payload is untrusted and the cap
    // applies before the text reaches this process's memory.
    command: ["sh", "-c", "wl-paste --no-newline | head -c 8192"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var value = Model.cleanText(text, root.fieldLimit)
        if (value === "") return
        root.pasted = true
        pastedTimer.restart()
        root.translate(value)
      }
    }
  }

  // The API key field takes the clipboard here: the compositor's own paste key
  // arrives as a global bind, and that is not what reaches a layer surface.
  Process {
    id: keyPasteReader
    command: ["sh", "-c", "wl-paste --no-newline | head -c 8192"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var value = String(text || "").trim()
        if (value === "") return
        root.fillKey(value)
      }
    }
  }

  Process {
    id: primaryReader
    command: ["sh", "-c", "wl-paste --primary --no-newline | head -c 8192"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.autoRead) return
        root.autoRead = false
        var value = Model.cleanText(text, root.fieldLimit)
        if (value === "") return
        if (value === root.inputText) return
        root.translate(value)
      }
    }
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // The field is the keyboard target while the panel is open: the panel is an
  // input first and a read-out second.
  function focusField() {
    var content = panel.loadedContent
    if (!content || !content.fieldItem) return
    content.fieldItem.forceActiveFocus()
    content.fieldItem.selectAll()
  }

  // Empties the line, the translation and the status: the panel back to its
  // opening state without closing it.
  function clearInput() {
    root.setInput("")
    root.outputText = ""
    root.statusLine = ""
    root.failed = false
    root.copied = false
    Qt.callLater(root.focusField)
  }

  function setInput(value) {
    root.inputText = String(value || "")
    var content = panel.loadedContent
    if (content && content.fieldItem) content.fieldItem.text = root.inputText
  }

  // ---- settings -----------------------------------------------------------

  // Writes back only the keys it was given: everything else in config.json
  // stays as it was. The file watcher then reloads the panel.
  function saveConfig(patch) {
    var next = {}
    for (var key in root.config) next[key] = root.config[key]
    for (var changed in patch) next[changed] = patch[changed]
    root.config = Model.parseConfig(JSON.stringify(next))
    // Written in-process, never through an argument: a payload on a command
    // line is readable in /proc for as long as the process lives, and this one
    // carries the key. The plugin directory is mode 700 and the file 600, so
    // the file stays private even for the moment before the chmod below.
    configFile.setText(JSON.stringify(next, null, 2) + "\n")
    Quickshell.execDetached(["chmod", "600", root.configPath])
  }

  function openSettings() {
    root.settingsOpen = !root.settingsOpen
    if (root.settingsOpen) {
      root.languageQuery = ""
      root.languageOpen = false
      root.fillLanguage(root.targetLang)
    } else {
      root.languageOpen = false
    }
  }

  // A code outside the table is refused here, not sent to the model: the
  // request carries the English name of the target.
  function setLanguage(code) {
    var value = String(code || "").trim().toLowerCase()
    if (!Model.isKnownLanguage(value)) {
      root.failed = true
      root.statusLine = "Unknown language code: " + value
      return false
    }
    root.failed = false
    root.languageOpen = false
    root.languageQuery = ""
    root.fillLanguage(value)
    root.setTargetLang(value)
    return true
  }

  // Enter in the language field: a code, or the English name of a language.
  function acceptLanguageText(value) {
    var text = String(value || "").trim()
    if (text === "") return
    if (Model.isKnownLanguage(text)) {
      root.setLanguage(text)
      return
    }
    var list = Model.languageList()
    for (var i = 0; i < list.length; i++) {
      if (list[i].name.toLowerCase() === text.toLowerCase()) {
        root.setLanguage(list[i].code)
        return
      }
    }
    root.failed = true
    root.statusLine = "Unknown language code: " + text
  }

  // ---- translation --------------------------------------------------------

  function translate(value) {
    root.autoRead = false
    var text = Model.cleanText(value, root.fieldLimit)
    if (text === "") {
      root.statusLine = "No text: select a line or type one"
      root.failed = false
      return
    }

    root.setInput(text)
    root.failed = false

    if (!Model.isKnownLanguage(root.targetLang)) {
      root.busy = false
      root.failed = true
      root.outputText = ""
      root.statusLine = "Unknown language code: " + root.targetLang
      return
    }

    if (String(root.config.apiKey) === "") {
      root.busy = false
      root.failed = true
      root.outputText = ""
      root.statusLine = "No key: fill in " + root.configPath
      return
    }

    root.requestSerial += 1
    var serial = root.requestSerial
    var pair = Model.resolvePair(text, root.targetLang)
    root.busy = true
    root.statusLine = pair.source.toUpperCase() + " → " + pair.target.toUpperCase()
      + " · translating…"

    Model.send(root.config, text, pair, function(result) {
      if (serial !== root.requestSerial) return
      root.busy = false
      root.failed = !result.ok
      if (!result.ok) {
        root.outputText = ""
        root.statusLine = result.error
        return
      }
      root.outputText = result.text
      root.statusLine = root.pairLabel(pair) + " · " + Model.modelLabel(result.model)
        + (result.fallback ? " · fallback" : "")
        + (result.truncated ? " · truncated at 8000 characters" : "")
      root.remember(text, result.text, pair)
      root.copyOutput()
    })
  }

  function pairLabel(pair) {
    return String(pair.source).toUpperCase() + " → " + String(pair.target).toUpperCase()
  }

  function remember(source, translation, pair) {
    var entry = Model.makeEntry(source, translation, pair, Date.now())
    root.history = Model.pushHistory(root.history, entry, Model.HISTORY_LIMIT)
    historyFile.setText(JSON.stringify(root.history, null, 2) + "\n")
  }

  function useHistoryEntry(entry) {
    if (!entry) return
    root.setInput(entry.source)
    root.outputText = String(entry.translation || "")
    root.failed = false
    root.statusLine = String(entry.pair || "").toUpperCase()
    root.copyOutput()
    Qt.callLater(root.focusField)
  }

  // Every finished translation lands on the clipboard: the panel is a
  // read-out, the clipboard is where the text is actually needed.
  function copyOutput() {
    if (root.outputText === "") return
    Quickshell.execDetached(["sh", "-c", "printf %s \"$1\" | wl-copy", "sh", root.outputText])
  }

  // Paste takes the clipboard, fills the input line and translates at once.
  function pasteFromClipboard() {
    if (clipboardReader.running) return
    clipboardReader.running = true
  }

  // The icon answers a click with a check mark for a moment. Only a click
  // does it: the automatic copy after a translation stays silent.
  function copyFromIcon() {
    if (root.outputText === "") return
    root.copyOutput()
    root.copied = true
    copiedTimer.restart()
  }

  function setTargetLang(code) {
    if (code === root.targetLang) {
      Qt.callLater(root.focusField)
      return
    }
    root.targetLang = code
    root.persistSettings({ targetLang: code })
    if (root.inputText !== "") root.translate(root.inputText)
    else Qt.callLater(root.focusField)
  }

  // Written straight into shell.json, the same way the clock stores its
  // format; the value comes back through `settings` on the host widget.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  onSettingsChanged: {
    var stored = root.setting("targetLang", "")
    if (stored !== "" && stored !== root.targetLang) root.targetLang = stored
  }

  // ---- config and history files -------------------------------------------

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    onLoaded: {
      root.config = Model.parseConfig(text())
      root.configProblem = String(root.config.apiKey) === ""
        ? "Key not set: " + root.configPath
        : ""
    }
    onLoadFailed: {
      root.config = Model.parseConfig("{}")
      root.configProblem = "No key file: " + root.configPath
    }
    onFileChanged: reload()
  }

  FileView {
    id: historyFile
    path: root.historyPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.history = Model.parseHistory(text())
    onLoadFailed: root.history = []
    onFileChanged: reload()
  }

  // Keeps the check mark on the copy icon long enough to be seen, then puts
  // the copy glyph back.
  Timer {
    id: copiedTimer
    interval: 1200
    onTriggered: root.copied = false
  }

  Timer {
    id: pastedTimer
    interval: 900
    onTriggered: root.pasted = false
  }

  // ---- surface ------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    // Anchored under the widget, so the popup follows wherever it is placed.
    centerOnBar: false
    // The inset belongs to this panel. The card keeps no padding of its own,
    // so all four sides come from the one value below.
    padding: 0
    focusTarget: (panel.loadedContent && panel.loadedContent.fieldItem)
      ? panel.loadedContent.fieldItem
      : null
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      id: keyCatcher
      // The input line owns the keyboard; the catcher only keeps the panel's
      // Escape and Tab routes reachable should focus ever land here.
      focus: false
      property Item fieldItem: inputField
      implicitWidth: panel.contentWidth
      implicitHeight: body.implicitHeight + root.pad * 2

      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // One content box, one inset, top to bottom.
      Column {
        id: body
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: root.pad
        spacing: root.rowGap

        // ---- header: mark top-left, languages in the gutter, gear top-right
        // The row is one icon square tall, so the mark and the gear sit on the
        // two top corners of the content box and the chips centre between them.
        Item {
          id: headerRow
          width: parent.width
          height: Math.max(root.iconSide, langRow.height)

          Text {
            id: widgetMark
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: root.fieldHeight
            height: root.iconSide
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            leftPadding: 0
            rightPadding: 0
            topPadding: 0
            bottomPadding: 0
            text: "\u6587"
            textFormat: Text.PlainText
            color: root.dimForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.subtitle
          }

          Row {
            id: langRow
            // Starts on the input text column, not on the panel edge.
            anchors.left: parent.left
            anchors.leftMargin: root.fieldHeight + Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.sm

            Repeater {
              model: root.languages

              Button {
                required property var modelData
                text: modelData.short
                selected: root.targetLang === modelData.code
                fontSize: Style.font.bodySmall
                foreground: root.contentForeground
                onClicked: root.setTargetLang(modelData.code)
              }
            }
          }

          // The gear shares the icon frame: same square, same offset, so the
          // three framed glyphs sit on one line down the panel.
          Item {
            id: settingsBox
            // Two pixels in from the card corner: the card's own rounded corner
            // clips a frame that sits exactly on it, and the frame then reads as
            // a shape with one corner cut. Inside the corner it stays a square.
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.rightMargin: Style.spacing.xxs
            anchors.topMargin: Style.spacing.xxs
            width: root.fieldHeight
            height: root.fieldHeight

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: settingsHover.containsMouse ? Style.hoverFill : Style.normalFill
              border.width: 1
              border.color: settingsHover.containsMouse
                ? Style.hoverBorderColor : Style.normalBorderColor
            }

            Text {
              id: settingsIcon
              anchors.centerIn: parent
              anchors.horizontalCenterOffset: -2
              anchors.verticalCenterOffset: 1
              width: root.iconSide
              height: root.iconSide
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
              text: "\uf013"
              textFormat: Text.PlainText
              color: (root.settingsOpen || settingsHover.containsMouse)
                ? root.contentForeground : root.dimForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.subtitle
            }

            MouseArea {
              id: settingsHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openSettings()
            }
          }
        }

        Connections {
          target: root
          function onFillLanguage(value) { languageField.text = value }
          function onFillKey(value) {
            keyField.text = value
            root.saveConfig({ apiKey: value })
          }
        }

        // ---- settings
        // Folded under the language row. Every field writes its own value on
        // Enter or on losing focus, so no Save button is needed.
        Column {
          id: settings
          width: parent.width
          spacing: root.rowGap
          visible: root.settingsOpen
          // Focus follows the section, after the layout has shown the field.
          onVisibleChanged: {
            if (visible) Qt.callLater(keyField.forceActiveFocus)
            else Qt.callLater(inputField.forceActiveFocus)
          }

          PanelSectionHeader {
            width: parent.width
            text: "Target language"
            foreground: root.dimForeground
            fontFamily: root.contentFontFamily
          }

          Item {
            width: parent.width
            height: languageField.height

            TextField {
              id: languageField
              anchors.left: parent.left
              anchors.right: parent.right
              // The caret sits inside this box, so the text stops short of it.
              rightPadding: root.iconSide + Style.spacing.controlPaddingX
              placeholderText: "Code or name, e.g. fr"
              foreground: root.contentForeground
              font.family: root.contentFontFamily
              inputMethodHints: Qt.ImhNoPredictiveText
              onTextEdited: {
                root.languageQuery = text
                root.languageOpen = true
              }
              onAccepted: root.acceptLanguageText(text)
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  root.languageOpen = false
                  event.accepted = true
                }
              }
            }

            Text {
              id: languageCaret
              anchors.right: languageField.right
              anchors.rightMargin: Style.spacing.xxs
              anchors.verticalCenter: languageField.verticalCenter
              width: root.fieldHeight
              height: root.fieldHeight
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
              leftPadding: 0
              rightPadding: 0
              text: root.languageOpen ? "\uf078" : "\uf054"
              textFormat: Text.PlainText
              color: languageCaretHover.containsMouse ? root.contentForeground : root.dimForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.subtitle

              MouseArea {
                id: languageCaretHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.languageOpen = !root.languageOpen
                  if (root.languageOpen) {
                    root.languageQuery = ""
                    languageField.text = ""
                  }
                }
              }
            }
          }

          ListView {
            id: languagePicker
            width: parent.width
            height: Math.min(contentHeight, root.historyRowHeight * 6)
            visible: root.languageOpen
            clip: true
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds
            model: root.languageOptions

            delegate: Item {
              required property var modelData
              width: languagePicker.width
              height: root.historyRowHeight

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: languageHover.containsMouse ? Style.hoverFill : "transparent"
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                x: Style.space(4)
                width: parent.width - Style.space(8)
                text: modelData.name + "  ·  " + modelData.code
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: modelData.code === root.targetLang
                  ? root.contentForeground : root.dimForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              MouseArea {
                id: languageHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setLanguage(modelData.code)
              }
            }
          }
          PanelSectionHeader {
            width: parent.width
            text: "API key"
            foreground: root.dimForeground
            fontFamily: root.contentFontFamily
          }

          Item {
            width: parent.width
            height: keyField.height

            TextField {
              id: keyField
              anchors.left: parent.left
              anchors.right: parent.right
              rightPadding: 2 * root.iconSide + Style.spacing.controlPaddingX
              text: root.config.apiKey
              password: !root.showKey
              placeholderText: "nvapi-…"
              foreground: root.contentForeground
              font.family: root.contentFontFamily
              inputMethodHints: Qt.ImhNoPredictiveText
              onEditingFinished: root.saveConfig({ apiKey: text.trim() })

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_V && (event.modifiers & Qt.MetaModifier)) {
                  keyPasteReader.running = true
                  event.accepted = true
                }
              }
            }

            Text {
              id: pasteKeyIcon
              anchors.right: showKeyIcon.left
              anchors.verticalCenter: keyField.verticalCenter
              width: root.iconSide
              height: root.fieldHeight
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
              text: "\uf0ea"
              textFormat: Text.PlainText
              color: pasteKeyHover.containsMouse ? root.contentForeground : root.dimForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.subtitle

              MouseArea {
                id: pasteKeyHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: keyPasteReader.running = true
              }
            }

            Text {
              id: showKeyIcon
              anchors.right: keyField.right
              anchors.rightMargin: Style.spacing.xxs + 3
              anchors.verticalCenter: keyField.verticalCenter
              width: root.fieldHeight
              height: root.fieldHeight
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
              leftPadding: 0
              rightPadding: 0
              text: root.showKey ? "\uf070" : "\uf06e"
              textFormat: Text.PlainText
              color: (root.showKey || showKeyHover.containsMouse)
                ? root.contentForeground : root.dimForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.subtitle

              MouseArea {
                id: showKeyHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.showKey = !root.showKey
              }
            }
          }

          PanelSectionHeader {
            width: parent.width
            text: "Model"
            foreground: root.dimForeground
            fontFamily: root.contentFontFamily
          }

          TextField {
            id: modelField
            width: parent.width
            text: root.config.model
            placeholderText: "nvidia/…"
            foreground: root.contentForeground
            font.family: root.contentFontFamily
            inputMethodHints: Qt.ImhNoPredictiveText
            onEditingFinished: root.saveConfig({ model: text.trim() })
          }

          PanelSectionHeader {
            width: parent.width
            text: "Fallback model"
            foreground: root.dimForeground
            fontFamily: root.contentFontFamily
          }

          TextField {
            id: fallbackField
            width: parent.width
            text: root.config.fallbackModel
            placeholderText: "empty for none"
            foreground: root.contentForeground
            font.family: root.contentFontFamily
            inputMethodHints: Qt.ImhNoPredictiveText
            onEditingFinished: root.saveConfig({ fallbackModel: text.trim() })
          }


        }

        // The translation UI steps aside while settings are open: the
        // panel then shows the settings only.
        Column {
          id: mainArea
          width: parent.width
          spacing: root.rowGap
          visible: !root.settingsOpen

          // ---- input
          // The paste icon sits on the first line of the input, in the same
          // frame as the copy icon: one click fills the line from the clipboard
          // and starts the translation.
          Item {
            id: inputRow
            width: parent.width
            height: inputField.height

            Item {
              id: pasteIconBox
              width: root.fieldHeight
              height: root.fieldHeight
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: pasteHover.pressed ? Style.pressedFill
                  : (pasteHover.containsMouse ? Style.hoverFill : Style.normalFill)
                border.width: 1
                border.color: pasteHover.containsMouse
                  ? Style.hoverBorderColor : Style.normalBorderColor
              }

              Text {
                id: pasteIcon
                anchors.centerIn: parent
                anchors.horizontalCenterOffset: -2
                anchors.verticalCenterOffset: 0
                width: root.iconSide
                height: root.iconSide
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: root.pasted ? "\uf00c" : "\uf0ea"
                textFormat: Text.PlainText
                color: (root.pasted || pasteHover.containsMouse || pasteHover.pressed)
                  ? root.contentForeground : root.dimForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.subtitle
              }

              MouseArea {
                id: pasteHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.pasteFromClipboard()
              }
            }

            TextField {
              id: inputField
              anchors.left: pasteIconBox.right
              anchors.leftMargin: Style.spacing.sm
              anchors.right: parent.right
              height: root.fieldHeight
              leftPadding: Style.space(4)
              // room for the clear glyph on the right
              rightPadding: root.fieldHeight
              focus: true
              placeholderText: "Text to translate"
              foreground: root.contentForeground
              font.family: root.contentFontFamily
              inputMethodHints: Qt.ImhNoPredictiveText

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  root.close()
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.translate(inputField.text)
                  event.accepted = true
                }
              }
            }

            // Erase what the line holds. It appears only while there is text, so
            // the row keeps one click target when the field is empty.
            Text {
              id: clearIcon
              // same box and same inset as the gear, so both glyph centres land
              // on one vertical line down the right side of the panel
              anchors.right: inputField.right
              anchors.rightMargin: Style.spacing.xxs
              anchors.verticalCenter: inputField.verticalCenter
              width: root.fieldHeight
              height: root.fieldHeight
              visible: inputField.text !== ""
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
              text: "\uf00d"
              textFormat: Text.PlainText
              color: clearHover.containsMouse ? root.contentForeground : root.dimForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.subtitle

              MouseArea {
                id: clearHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.clearInput()
              }
            }
          }

          // ---- status
          Text {
            width: parent.width
            visible: root.statusLine !== ""
            text: root.statusLine
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.failed ? Commons.Color.urgent : root.dimForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // ---- translation
          // The copy action is an icon on the first line of the translation, not
          // a button of its own: one click target, no extra row.
          Item {
            id: outputRow
            width: parent.width
            visible: root.outputText !== ""
            implicitHeight: Math.max(copyIconBox.height, outputBody.implicitHeight)
            height: implicitHeight

            // A fixed square, sized from the font and not from the glyph: the
            // check mark resolves through a fallback font and would resize the
            // box on its own. It is centred on the first line of the text, so the
            // copy glyph and the check share one frame. The fill and the pointer
            // area reach two pixels past the box on every side.
            Item {
              id: copyIconBox
              width: root.fieldHeight
              height: root.fieldHeight
              anchors.left: parent.left
              anchors.top: outputBody.top
              anchors.topMargin: Math.max(0, Math.round(
                (outputBody.contentHeight / Math.max(1, outputBody.lineCount) - root.fieldHeight) / 2))

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: copyHover.pressed ? Style.pressedFill
                  : (copyHover.containsMouse ? Style.hoverFill : Style.normalFill)
                border.width: 1
                border.color: copyHover.containsMouse
                  ? Style.hoverBorderColor : Style.normalBorderColor
              }

              Text {
                id: copyIcon
                anchors.centerIn: parent
                anchors.horizontalCenterOffset: -2
                anchors.verticalCenterOffset: 0
                width: root.iconSide
                height: root.iconSide
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: root.copied ? "\uf00c" : "\uf24d"
                textFormat: Text.PlainText
                color: (root.copied || copyHover.containsMouse || copyHover.pressed)
                  ? root.contentForeground : root.dimForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.subtitle
              }

              MouseArea {
                id: copyHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.copyFromIcon()
              }
            }

            TextEdit {
              id: outputBody
              anchors.left: copyIconBox.right
              anchors.leftMargin: Style.spacing.sm
              anchors.right: parent.right
              readOnly: true
              selectByMouse: true
              wrapMode: TextEdit.Wrap
              text: root.outputText
              color: root.contentForeground
              selectionColor: Style.selectionFill
              selectedTextColor: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.subtitle
            }
          }

          // ---- hint and history header, on one line
          // The hint sits on the bottom-left corner of the content box, the
          // History header on the bottom-right one; the row is exactly as tall
          // as the taller of the two, so neither leaves a gap under it.
          Item {
            id: footerRow
            width: parent.width
            height: Math.max(hintText.implicitHeight, historyHeader.implicitHeight)

            Text {
              id: hintText
              anchors.left: parent.left
              anchors.bottom: parent.bottom
              text: "Enter translates · Esc closes"
              textFormat: Text.PlainText
              color: root.dimForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }

            PanelSectionHeader {
              id: historyHeader
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              visible: root.history.length > 0
              horizontalAlignment: Text.AlignRight
              text: (root.historyOpen ? "\uf078" : "\uf054") + "  History"
              foreground: root.dimForeground
              fontFamily: root.contentFontFamily
            }

            MouseArea {
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              width: historyHeader.width
              height: historyHeader.height
              visible: root.history.length > 0
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.historyOpen = !root.historyOpen
            }
          }

          // ---- history rows
          // A ListView, not a Column: twenty entries stay stored, ten show, the
          // wheel reaches the other ten.
          ListView {
            id: historyList
            width: parent.width
            height: Math.min(contentHeight, root.historyRowHeight * root.historyVisibleRows)
            visible: root.historyOpen
            clip: true
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds
            model: root.history

            delegate: Item {
              required property var modelData
              width: historyList.width
              height: root.historyRowHeight

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: historyHover.containsMouse ? Style.hoverFill : "transparent"
              }

              Text {
                id: historyLabel
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Style.space(8)
                x: Style.space(4)
                text: Model.preview(modelData.source, 48) + "  →  " + Model.preview(modelData.translation, 48)
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: root.dimForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              MouseArea {
                id: historyHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.useHistoryEntry(modelData)
              }
            }
          }        }

      }
    }
  }
}
