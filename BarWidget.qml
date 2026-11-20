import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Translator entry point for the bar: one glyph, a popout panel, and the IPC
// routes a caller may use.
//
// Click opens the panel; the panel reads the primary selection itself when it
// opens, so no route here has to touch the selection. `translate <text>` hands
// a string in from outside.
BarWidget {
  id: root
  moduleName: "L1-translator"

  // A glyph from the bundled Nerd Font; override with {"icon": "..."} in the
  // shell.json entry when a theme's font lacks it. The default is the mark the
  // panel header carries, so the bar and the popup show the same sign.
  readonly property string iconGlyph: setting("icon", "\u6587")
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

  // ---- A caller hands text in; nothing here reads a selection. The panel
  //      does that on its own when it opens, which keeps this widget free of
  //      clipboard access and of a route that would read the user's selection.
  function translate(value) {
    root.open()
    if (panelLoader.item) panelLoader.item.translate(String(value || ""))
  }

  // One route, and it takes the text from the caller: no route here reads the
  // user's selection, so a local process cannot make the plugin pull what is
  // highlighted and send it anywhere.
  //   omarchy-shell shell call L1-translator translate "hallo"
  // The panel lifecycle is reached through the host route `shell toggle <id>`,
  // which the bar answers itself.
  ShellIpc {
    target: "L1-translator"

    function translate(text: string): void { root.translate(text) }
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
