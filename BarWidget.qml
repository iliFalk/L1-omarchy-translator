import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Translator entry point for the bar: one glyph, a popout panel, and the IPC
// routes the hotkey uses.
//
// Click opens the panel for a typed line. `translateSelection` reads the
// primary selection (the text highlighted in the focused window) and opens the
// panel on its translation; `translate <text>` does the same for text handed
// in by a caller.
BarWidget {
  id: root
  moduleName: "L1-translator"

  // A glyph from the bundled Nerd Font; override with {"icon": "..."} in the
  // shell.json entry when a theme's font lacks it.
  readonly property string iconGlyph: setting("icon", "\uf1ab")
  readonly property string tooltipLine: panelLoader.item ? panelLoader.item.tooltipLine : ""

  // ---- Panel lifecycle. Bar.findPanelWidget needs open/close/opened on the
  //      bar-widget root, so every route below forwards to the loaded panel.
  readonly property bool opened: panelLoader.item
    ? panelLoader.item.opened === true
    : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // ---- Reading what the user highlighted. The panel is opened only once the
  //      text is in hand: opening it takes the keyboard, and a surface that
  //      takes focus is the wrong moment to ask the compositor for a selection.
  function hasText(value) {
    return String(value || "").replace(/\s+/g, "") !== ""
  }

  function acceptSelection(value, fromPrimary) {
    if (!root.hasText(value) && fromPrimary) {
      clipboardProcess.running = true
      return
    }
    if (!root.hasText(value)) {
      root.open()
      return
    }
    root.translate(String(value))
  }

  function translateSelection() {
    if (primaryProcess.running) return
    primaryProcess.running = true
  }

  function translate(value) {
    root.open()
    if (panelLoader.item) panelLoader.item.translate(String(value || ""))
  }

  Process {
    id: primaryProcess
    command: ["wl-paste", "--primary", "--no-newline"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.acceptSelection(text, true)
    }
  }

  Process {
    id: clipboardProcess
    command: ["wl-paste", "--no-newline"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.acceptSelection(text, false)
    }
  }

  // Routes reached by the hotkey and by hand:
  //   omarchy-shell shell call L1-translator translateSelection
  //   omarchy-shell shell call L1-translator translate "hallo"
  ShellIpc {
    target: "L1-translator"

    function translateSelection(): void { root.translateSelection() }
    function translate(text: string): void { root.translate(text) }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.iconGlyph
    tooltipText: root.tooltipLine !== "" ? root.tooltipLine : "Translate · SUPER+Y"

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
    }
  }
}
