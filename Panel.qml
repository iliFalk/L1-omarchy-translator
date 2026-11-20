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
    command: ["wl-paste", "--no-newline"]
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

  Process {
    id: primaryReader
    command: ["wl-paste", "--primary", "--no-newline"]
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
    configFile.setText(JSON.stringify(next, null, 2) + "\n")
    // A file Quickshell writes gets the default umask, and this one holds the
    // key: keep it readable by its owner only.
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
      implicitHeight: body.implicitHeight

      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: body
        width: parent.width
        spacing: Style.space(10)

        // ---- target language and the settings toggle
        Item {
          id: languageRow
          width: parent.width
          height: langRow.implicitHeight

          // The widget mark, in the same column as the paste and copy icons.
          Item {
            id: widgetMark
            readonly property int side: Math.ceil(Style.font.subtitle * 1.4)
            width: side
            height: side
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter

            Text {
              anchors.fill: parent
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
              text: "\u6587"
              textFormat: Text.PlainText
              color: root.dimForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.subtitle
            }
          }

          Row {
            id: langRow
            // Starts on the input text column, not on the panel edge.
            x: Style.space(25)
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

          Text {
            id: settingsIcon
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "\uf013"
            textFormat: Text.PlainText
            color: (root.settingsOpen || settingsHover.containsMouse)
              ? root.contentForeground : root.dimForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.subtitle
          }

          MouseArea {
            id: settingsHover
            anchors.fill: settingsIcon
            anchors.margins: -4
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openSettings()
          }
        }

        Connections {
          target: root
          function onFillLanguage(value) { languageField.text = value }
        }

        // ---- settings
        // Folded under the language row. Every field writes its own value on
        // Enter or on losing focus, so no Save button is needed.
        Column {
          id: settings
          width: parent.width
          spacing: Style.space(6)
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
              width: parent.width
              rightPadding: Style.space(32)
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
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: root.languageOpen ? "\uf078" : "\uf054"
              textFormat: Text.PlainText
              color: languageCaretHover.containsMouse ? root.contentForeground : root.dimForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.subtitle

              MouseArea {
                id: languageCaretHover
                anchors.fill: parent
                anchors.margins: -4
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
              width: parent.width
              rightPadding: Style.space(32)
              text: root.config.apiKey
              password: !root.showKey
              placeholderText: "nvapi-…"
              foreground: root.contentForeground
              font.family: root.contentFontFamily
              inputMethodHints: Qt.ImhNoPredictiveText
              onEditingFinished: root.saveConfig({ apiKey: text.trim() })
            }

            Text {
              id: showKeyIcon
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: root.showKey ? "\uf070" : "\uf06e"
              textFormat: Text.PlainText
              color: (root.showKey || showKeyHover.containsMouse)
                ? root.contentForeground : root.dimForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.subtitle

              MouseArea {
                id: showKeyHover
                anchors.fill: parent
                anchors.margins: -4
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
          spacing: Style.space(10)
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
              readonly property int side: Math.ceil(Style.font.subtitle * 1.4)
              width: side
              height: side
              anchors.top: parent.top
              anchors.topMargin: Math.round((inputField.height - side) / 2)

              Rectangle {
                anchors.fill: parent
                anchors.margins: -2
                radius: Style.cornerRadius
                color: pasteHover.pressed ? Style.pressedFill
                  : (pasteHover.containsMouse ? Style.hoverFill : "transparent")
              }

              Text {
                anchors.fill: parent
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                rightPadding: 3
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
                anchors.margins: -2
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.pasteFromClipboard()
              }
            }

            TextField {
              id: inputField
              anchors.left: pasteIconBox.right
              anchors.leftMargin: Style.space(6)
              width: parent.width - pasteIconBox.width - Style.space(6)
              leftPadding: Style.space(4)
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
              readonly property int side: Math.ceil(Style.font.subtitle * 1.4)
              width: side
              height: side
              anchors.top: outputBody.top
              anchors.topMargin: Math.round(
                (outputBody.contentHeight / Math.max(1, outputBody.lineCount) - side) / 2)

              Rectangle {
                anchors.fill: parent
                anchors.margins: -2
                radius: Style.cornerRadius
                color: copyHover.pressed ? Style.pressedFill
                  : (copyHover.containsMouse ? Style.hoverFill : "transparent")
              }

              Text {
                id: copyIcon
                anchors.fill: parent
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                // The glyph ink sits right of its advance centre; this pulls the
                // centre of the ink back onto the centre of the frame.
                rightPadding: 3
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
                anchors.margins: -2
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.copyFromIcon()
              }
            }

            TextEdit {
              id: outputBody
              anchors.left: copyIconBox.right
              anchors.leftMargin: Style.space(10)
              width: parent.width - copyIconBox.width - Style.space(10)
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
          // The hint holds the left edge, the History header the right one, so
          // the row costs a single line whether or not history exists.
          Item {
            id: hintRow
            width: parent.width
            height: Math.max(hintText.implicitHeight, historyHeader.implicitHeight)

            Text {
              id: hintText
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Enter translates · Esc closes"
              textFormat: Text.PlainText
              color: root.dimForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }

            PanelSectionHeader {
              id: historyHeader
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: root.history.length > 0
              horizontalAlignment: Text.AlignRight
              text: (root.historyOpen ? "\uf078" : "\uf054") + "  History"
              foreground: root.dimForeground
              fontFamily: root.contentFontFamily
            }

            MouseArea {
              anchors.right: parent.right
              width: historyHeader.width
              height: parent.height
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
            width: body.width
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
