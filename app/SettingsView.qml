import QtQuick
import QtQuick.Dialogs
import QtQuick.Layouts
import qs.Commons
import "Model.js" as Model
import "Keymap.js" as Keymap

// Settings: your profile (name, username, bio, photo), your account (what Omagram keeps on this
// computer, the devices signed in, signing out), every keyboard shortcut in Omagram, and the
// shortcuts that work anywhere.
//
// ↑/↓ or j/k choose. Enter changes a field of your profile (Enter saves it, Esc leaves it as it
// was; Backspace on the photo removes it). Enter opens an account row -- anything that changes the account asks first,
// answered with Enter or Esc -- or records new keys for an action (the next combination you press
// replaces its keys); A adds a key, Backspace removes its last key, R resets it, Esc closes. While
// recording, Esc cancels. These keys are fixed on purpose: whatever you do to the other shortcuts,
// this screen always works, and Ctrl+, cannot be lost for good (the gear in the chat list opens it
// too).
FocusScope {
  id: settings

  property var app
  property int cursor: 1
  property string recording: ""      // the action being recorded, "" when none
  property bool recordingAdds: false
  property string error: ""
  property var storage: null         // what storage.stats last said
  property var sessions: []
  property bool sessionsOpen: false
  property var confirm: null         // { text, run }: a question waiting for Enter or Esc
  property real nowMs: Date.now()
  property var profile: null         // what profile.get last said
  property var editing: null         // { field, label }: a field of your profile being changed
  property bool photoBusy: false
  readonly property var profileChat: Model.profileChat(settings.profile)

  readonly property var overrides: settings.app ? settings.app.shortcuts : ({})
  readonly property var globals: settings.app ? settings.app.globalShortcuts : ({})
  readonly property var globalStatus: settings.app ? settings.app.globalStatus : ({})
  readonly property var rows: settings.buildRows()
  readonly property var current: settings.rows[settings.cursor] || null
  readonly property var accountKinds: ["profilePhoto", "profileField", "profilePhone", "privacy", "blocked", "blockedSender", "password",
                                       "passwordOff", "passwordCode", "accountTtl", "autoDelete", "proxy", "proxyAdd", "reactionsSeen", "sound", "soundHear", "scope", "previews", "download", "folder", "newFolder",
                                       "folderName", "folderFlag", "folderChat", "folderAdd", "folderSave", "folderDelete",
                                       "storage", "sessions", "session", "otherSessions", "logout"]

  signal closed()

  onVisibleChanged: {
    if (!visible) return
    settings.recording = ""
    settings.error = ""
    settings.confirm = null
    settings.editing = null
    settings.flow = null
    settings.editorError = ""
    settings.folderOpen = null
    settings.nowMs = Date.now()
    settings.forceActiveFocus()
    settings.loadProfile()
    settings.loadPrivacy()
    settings.loadNotifications()
    settings.loadProxies()
    settings.loadFolders()
    settings.loadStorage()
    settings.loadSessions()
  }

  function loadProfile() {
    settings.app.request("profile.get", {}, function (answer) { if (answer.ok) settings.profile = answer.result })
  }

  function loadStorage() {
    settings.app.request("storage.stats", {}, function (answer) { if (answer.ok) settings.storage = answer.result })
  }

  function loadSessions() {
    settings.app.request("sessions.list", {}, function (answer) { if (answer.ok) settings.sessions = answer.result.sessions || [] })
  }

  function buildRows() {
    if (settings.folderOpen) return settings.folderRows()
    var out = [{ kind: "header", title: "Profile", note: "" },
               { kind: "profilePhoto", label: "Photo" },
               { kind: "profileField", field: "firstName", label: "First name" },
               { kind: "profileField", field: "lastName", label: "Last name" },
               { kind: "profileField", field: "username", label: "Username" },
               { kind: "profileField", field: "bio", label: "Bio" },
               { kind: "profilePhone", label: "Phone number" },
               { kind: "header", title: "Privacy and security", note: "" },
               { kind: "privacy", id: "status", label: "Last seen and online" },
               { kind: "privacy", id: "photo", label: "Profile photo" },
               { kind: "privacy", id: "phone", label: "Phone number" },
               { kind: "privacy", id: "findByPhone", label: "Finding you by your number" },
               { kind: "privacy", id: "bio", label: "Bio" },
               { kind: "privacy", id: "birthdate", label: "Date of birth" },
               { kind: "privacy", id: "forwards", label: "Your name on messages others forward" },
               { kind: "privacy", id: "calls", label: "Calls" },
               { kind: "privacy", id: "invites", label: "Adding you to groups and channels" },
               { kind: "blocked", label: "Blocked" }]
    if (settings.blockedOpen && settings.blocked)
      for (var b = 0; b < settings.blocked.senders.length; b++) out.push({ kind: "blockedSender", sender: settings.blocked.senders[b] })
    out.push({ kind: "password", label: "Two-step verification" })
    if (settings.password && settings.password.emailCodePattern) out.push({ kind: "passwordCode", label: "Type the code from the email" })
    if (settings.password && settings.password.hasPassword) out.push({ kind: "passwordOff", label: "Turn two-step verification off" })
    out.push({ kind: "accountTtl", label: "Delete my account if I am away for" },
             { kind: "autoDelete", label: "Auto-delete messages in chats you start" },
             { kind: "header", title: "Notifications", note: "For chats that have no notification setting of their own" },
             { kind: "scope", id: "private", label: "Private chats" },
             { kind: "scope", id: "groups", label: "Groups" },
             { kind: "scope", id: "channels", label: "Channels" },
             { kind: "previews", label: "Message text in notifications" },
             { kind: "sound", label: "A sound of their own for each person" },
             { kind: "soundHear", label: "Hear yours" },
             { kind: "header", title: "Chats", note: "" },
             { kind: "reactionsSeen", label: "Reactions to your messages" },
             { kind: "header", title: "Automatic downloads", note: "Stickers and voice messages always download: they are small" },
             { kind: "download", id: "photos", label: "Photos" },
             { kind: "download", id: "gifs", label: "GIFs and round video messages" },
             { kind: "download", id: "videos", label: "Videos" },
             { kind: "download", id: "files", label: "Files and music" },
             { kind: "header", title: "Chat folders", note: "Enter opens a folder  ·  [ and ] move it earlier or later" })
    for (var f = 0; f < settings.folders.length; f++) out.push({ kind: "folder", folder: settings.folders[f], label: settings.folders[f].name })
    out.push({ kind: "newFolder", label: "New folder" },
             { kind: "header", title: "Connection",
               note: (Model.connectionText(settings.app.connection) ? Model.connectionText(settings.app.connection) + "  ·  " : "")
                     + "Enter uses a proxy or stops using it  ·  Backspace removes it" })
    for (var p = 0; p < settings.proxies.length; p++)
      out.push({ kind: "proxy", proxy: settings.proxies[p], label: settings.proxies[p].server + ":" + settings.proxies[p].port })
    out.push({ kind: "proxyAdd", type: "socks5", label: "Add a SOCKS5 proxy" },
             { kind: "proxyAdd", type: "mtproto", label: "Add an MTProto proxy" },
             { kind: "proxyAdd", type: "http", label: "Add an HTTP proxy" },
             { kind: "proxyAdd", type: "link", label: "Add a proxy from its link" },
             { kind: "header", title: "Account", note: "" },
             { kind: "storage", label: "Storage on this computer" },
             { kind: "sessions", label: "Devices signed in" })
    if (settings.sessionsOpen) {
      for (var i = 0; i < settings.sessions.length; i++) out.push({ kind: "session", session: settings.sessions[i] })
      if (settings.sessions.some(function (s) { return !s.current })) out.push({ kind: "otherSessions", label: "Sign out every other device" })
    }
    out.push({ kind: "logout", label: "Sign out of Telegram on this computer" })
    out.push({ kind: "header", title: "Shortcuts that work anywhere",
               note: "Registered with Hyprland, never written into your config. They need Super, Ctrl or Alt." },
             { kind: "global", id: "global.quickReply", label: "Quick reply: find a chat and answer" },
             { kind: "global", id: "global.panel", label: "The bar panel" },
             { kind: "global", id: "global.openWindow", label: "Open Omagram" })
    for (var s = 0; s < Keymap.SECTIONS.length; s++) {
      var section = Keymap.SECTIONS[s]
      out.push({ kind: "header", title: section.title,
                 note: section.app === "shell" ? "In Omarchy's shell" : "" })
      for (var a = 0; a < Keymap.ACTIONS.length; a++) {
        var action = Keymap.ACTIONS[a]
        if (action.id.split(".")[0] === section.id) out.push({ kind: "action", id: action.id, label: action.label })
      }
    }
    return out
  }

  function move(delta) {
    var i = Math.max(0, Math.min(settings.rows.length - 1, settings.cursor + delta))
    var dir = delta < 0 ? -1 : 1
    while (settings.rows[i] && settings.rows[i].kind === "header" && i + dir >= 0 && i + dir < settings.rows.length) i += dir
    while (settings.rows[i] && settings.rows[i].kind === "header" && i - dir >= 0 && i - dir < settings.rows.length) i -= dir
    settings.cursor = i
    list.positionViewAtIndex(i, ListView.Contain)
  }

  function editable(row) {
    return !!row && (row.kind === "action" || row.kind === "global")
  }

  function keysOf(row) {
    if (!settings.editable(row)) return []
    if (row.kind === "global") return settings.globals[row.id] ? [settings.globals[row.id]] : []
    return Keymap.keysFor(settings.overrides, row.id)
  }

  function changed(row) {
    if (!settings.editable(row)) return false
    if (row.kind === "global") return !!settings.globals[row.id]
    return Object.prototype.hasOwnProperty.call(settings.overrides, row.id)
  }

  function startRecording(adds) {
    var row = settings.current
    if (!settings.editable(row)) return
    settings.error = ""
    settings.recordingAdds = adds && row.kind === "action"
    settings.recording = row.id
  }

  function send(overrides, globals) {
    settings.error = ""
    settings.app.request("settings.set", { settings: { shortcuts: overrides, globalShortcuts: globals } }, function (answer) {
      if (!answer.ok) settings.error = answer.error || "The settings could not be saved"
    })
  }

  function withGlobal(id, combo) {
    var next = {}
    for (var k in settings.globals) if (k !== id) next[k] = settings.globals[k]
    if (combo) next[id] = combo
    return next
  }

  function capture(event) {
    var mods = event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.ShiftModifier | Qt.MetaModifier)
    if (event.key === Qt.Key_Escape && !mods) {
      settings.recording = ""
      return
    }
    var sequence = Keymap.fromEvent(event.key, event.modifiers)
    if (sequence === "") return   // a modifier on its own: wait for the key
    var id = settings.recording
    settings.recording = ""
    if (id.indexOf("global.") === 0) {
      var combo = Keymap.toHyprland(sequence)
      if (!combo) {
        settings.error = Keymap.label(sequence) + " cannot work anywhere: use Super, Ctrl or Alt with a letter, digit or named key"
        return
      }
      settings.send(settings.overrides, settings.withGlobal(id, combo))
      return
    }
    var keys = settings.recordingAdds ? Keymap.keysFor(settings.overrides, id).concat([sequence]) : [sequence]
    settings.send(Keymap.withKeys(settings.overrides, id, keys), settings.globals)
  }

  function removeLast() {
    var row = settings.current
    if (row && row.kind === "profilePhoto") { settings.askRemovePhoto(); return }
    if (row && row.kind === "proxy") { settings.askRemoveProxy(row.proxy); return }
    if (!settings.editable(row)) return
    if (row.kind === "global") {
      settings.send(settings.overrides, settings.withGlobal(row.id, ""))
      return
    }
    var keys = Keymap.keysFor(settings.overrides, row.id)
    keys.pop()
    settings.send(Keymap.withKeys(settings.overrides, row.id, keys), settings.globals)
  }

  function reset() {
    var row = settings.current
    if (!settings.editable(row)) return
    if (row.kind === "global") settings.send(settings.overrides, settings.withGlobal(row.id, ""))
    else settings.send(Keymap.withKeys(settings.overrides, row.id, Keymap.defaultsFor(row.id)), settings.globals)
  }

  function statusText(id) {
    var state = settings.globalStatus[id] || "off"
    if (!settings.globals[id]) return "Not set"
    return ({ active: "Active", taken: "Taken by another Hyprland binding", failed: "Hyprland refused it",
              unavailable: "Only inside Hyprland", off: "Not active" })[state] || state
  }

  // ---------------------------------------------------------------- your profile

  function startEditing(row) {
    if (!settings.profile) { settings.error = "Your profile is still loading"; return }
    settings.error = ""
    settings.confirm = null
    settings.editing = { field: row.field, label: row.label }
    editor.text = settings.profile[row.field] || ""
    editor.forceActiveFocus()
  }

  function cancelEditing() {
    settings.editing = null
    settings.flow = null          // with what was typed for two-step verification
    settings.editorError = ""
    editor.text = ""
    settings.forceActiveFocus()
  }

  function saveEditing() {
    if (settings.flow) { settings.flowNext(); return }
    if (settings.editing && settings.editing.field === "folderName") {
      var folderName = editor.text.trim()
      if (Model.profileProblem("folderName", folderName) !== "") return   // the field shows what is wrong
      settings.changeFolder({ name: folderName })
      settings.cancelEditing()
      return
    }
    var editing = settings.editing
    var profile = settings.profile
    if (!editing || !profile) return
    var text = editor.text.trim()
    if (Model.profileProblem(editing.field, text) !== "") return   // the field shows what is wrong
    var command = "profile.setBio"
    var args = { bio: text }
    if (editing.field === "firstName" || editing.field === "lastName") {
      command = "profile.setName"
      args = { firstName: editing.field === "firstName" ? text : profile.firstName,
               lastName: editing.field === "lastName" ? text : profile.lastName }
    } else if (editing.field === "username") {
      text = text.replace(/^@/, "")
      command = "profile.setUsername"
      args = { username: text }
    }
    settings.cancelEditing()
    if (text === (profile[editing.field] || "")) return
    settings.app.request(command, args, function (answer) {
      var problem = answer.ok ? "" : Model.profileError(answer.error)
      if (problem !== "") settings.error = problem
      settings.loadProfile()
    })
  }

  function urlToPath(url) {
    var s = String(url)
    return s.indexOf("file://") === 0 ? decodeURIComponent(s.slice(7)) : ""
  }

  // Telegram takes a square JPEG: the service cuts one from the middle of the picture.
  function setPhoto(path) {
    settings.forceActiveFocus()
    if (!path) return
    settings.error = ""
    settings.photoBusy = true
    settings.app.request("profile.setPhoto", { path: path }, function (answer) {
      settings.photoBusy = false
      if (!answer.ok) settings.error = Model.profileError(answer.error)
      settings.loadProfile()
    })
  }

  function askRemovePhoto() {
    if (!settings.profile || !(settings.profile.photo || settings.profile.photoId)) return
    settings.ask("Remove your profile photo? If you had earlier ones, the one before it shows instead.", function () {
      settings.app.request("profile.deletePhoto", {}, function (answer) {
        if (!answer.ok) settings.error = Model.profileError(answer.error)
        settings.loadProfile()
      })
    })
  }

  // ---------------------------------------------------------------- privacy and security

  property var privacy: ({})         // setting id -> { base, allowed, restricted }, or null when Telegram did not say
  property var blocked: null         // { total, senders }
  property bool blockedOpen: false
  property var password: null        // what password.get last said
  property int accountTtl: 0
  property int defaultAutoDelete: -1 // seconds; -1 until Telegram has said
  property var flow: null            // two-step verification being changed, or a proxy added: { kind, steps, step, values }
  property string editorError: ""

  function loadPrivacy() {
    settings.app.request("privacy.get", {}, function (answer) { if (answer.ok) settings.privacy = answer.result.settings || ({}) })
    settings.app.request("password.get", {}, function (answer) { if (answer.ok) settings.password = answer.result })
    settings.app.request("account.ttl", {}, function (answer) { if (answer.ok) settings.accountTtl = answer.result.days || 0 })
    settings.app.request("autoDelete.default", {}, function (answer) { if (answer.ok) settings.defaultAutoDelete = answer.result.seconds })
    settings.loadBlocked()
  }

  function loadBlocked() {
    settings.app.request("blocked.list", {}, function (answer) { if (answer.ok) settings.blocked = answer.result })
  }

  function changePrivacy(row) {
    var current = settings.privacy[row.id]
    if (!current) { settings.error = "Telegram has not said who can see that yet"; return }
    settings.error = ""
    settings.app.request("privacy.set", { setting: row.id, base: Model.nextPrivacy(row.id, current.base) }, function (answer) {
      if (!answer.ok) { settings.error = answer.error || "Telegram did not take the change"; return }
      var next = {}
      for (var k in settings.privacy) next[k] = settings.privacy[k]
      next[row.id] = answer.result
      settings.privacy = next
    })
  }

  function askUnblock(sender) {
    settings.ask("Unblock " + sender.name + "?", function () {
      settings.app.request("blocked.unblock", { type: sender.type, id: sender.id }, function (answer) {
        if (!answer.ok) settings.error = answer.error || "Could not unblock"
        settings.loadBlocked()
      })
    })
  }

  function changeAccountTtl() {
    settings.app.request("account.setTtl", { days: Model.nextTtl(settings.accountTtl) }, function (answer) {
      if (answer.ok) settings.accountTtl = answer.result.days
      else settings.error = answer.error || "Telegram did not take the change"
    })
  }

  function changeDefaultAutoDelete() {
    if (settings.defaultAutoDelete < 0) return
    settings.app.request("autoDelete.setDefault", { seconds: Model.nextAutoDelete(settings.defaultAutoDelete) }, function (answer) {
      if (answer.ok) settings.defaultAutoDelete = answer.result.seconds
      else settings.error = answer.error || "Telegram did not take the change"
    })
  }

  // Two-step verification is changed one field at a time in the bar above the list; what is typed
  // is kept only until it is sent, or the change is left with Esc.
  function startPasswordFlow(kind) {
    settings.error = ""
    settings.confirm = null
    settings.flow = { kind: kind, steps: Model.passwordSteps(kind), step: 0, values: {} }
    settings.showFlowStep()
  }

  function showFlowStep() {
    var step = settings.flow.steps[settings.flow.step]
    settings.editorError = ""
    settings.editing = { field: step.key, label: step.label, secret: step.secret === true, placeholder: step.placeholder || "" }
    editor.text = ""
    editor.forceActiveFocus()
  }

  function flowNext() {
    var flow = settings.flow
    var step = flow.steps[flow.step]
    var problem = flow.kind === "proxy" ? Model.proxyStepProblem(step, editor.text) : Model.passwordStepProblem(step, editor.text, flow.values)
    if (problem !== "") { settings.editorError = problem; return }
    flow.values[step.key] = step.secret ? editor.text : editor.text.trim()
    if (flow.step + 1 < flow.steps.length) {
      flow.step++
      settings.showFlowStep()
      return
    }
    var values = flow.values
    var kind = flow.kind
    settings.cancelEditing()
    if (kind === "proxy") {
      settings.addProxy(flow.proxyType, values)
      return
    }
    if (kind === "code") {
      settings.app.request("password.checkEmailCode", { code: values.code }, settings.passwordAnswered)
      return
    }
    var args = { oldPassword: values.oldPassword || "", newPassword: kind === "off" ? "" : values.newPassword, hint: values.hint || "" }
    if (values.email) args.email = values.email
    settings.app.request("password.set", args, settings.passwordAnswered)
  }

  function passwordAnswered(answer) {
    if (!answer.ok) { settings.error = Model.passwordError(answer.error); return }
    settings.password = answer.result
    if (answer.result.emailCodePattern) settings.startPasswordFlow("code")
  }

  // ---------------------------------------------------------------- notifications

  property var scopes: ({})          // "private", "groups", "channels" -> { muted, preview }, or null

  function loadNotifications() {
    settings.app.request("notifications.get", {}, function (answer) { if (answer.ok) settings.scopes = answer.result.scopes || ({}) })
  }

  function changeScope(scope, change) {
    if (!settings.scopes[scope]) { settings.error = "Telegram has not said these notifications yet"; return }
    settings.error = ""
    var args = { scope: scope }
    for (var key in change) args[key] = change[key]
    settings.app.request("notifications.set", args, function (answer) {
      if (!answer.ok) { settings.error = answer.error || "Telegram did not take the change"; return }
      var next = {}
      for (var s in settings.scopes) next[s] = settings.scopes[s]
      next[scope] = { muted: answer.result.muted, preview: answer.result.preview }
      settings.scopes = next
    })
  }

  // One row for message text in the notifications of every type of chat: shown everywhere, unless it already is.
  function togglePreviews() {
    var show = Model.previewsText(settings.scopes) !== "Shown"
    var all = ["private", "groups", "channels"]
    for (var i = 0; i < all.length; i++) settings.changeScope(all[i], { preview: show })
  }

  // ---------------------------------------------------------------- chat folders

  property var folders: []           // what folders.get last said, in Telegram's order
  property var folderOpen: null      // the folder being edited: a copy, with id 0 for a new one
  property string pickerFor: ""      // "included" or "excluded": where the chat picked goes
  readonly property bool pickerOpen: chatPicker.visible

  function loadFolders() {
    settings.app.request("folders.get", {}, function (answer) { if (answer.ok) settings.folders = answer.result.folders || [] })
  }

  // A folder's own page: its name, the kinds of chats it takes, what it leaves out, the chats always and never
  // in it, then saving or deleting it.
  function folderRows() {
    var f = settings.folderOpen
    var out = [{ kind: "header", title: f.id ? "Folder “" + f.name + "”" : "New folder", note: "Enter changes a row  ·  Esc goes back without saving" },
               { kind: "folderName", label: "Name" },
               { kind: "header", title: "The chats it takes", note: "" }]
    for (var k = 0; k < Model.FOLDER_KINDS.length; k++) out.push({ kind: "folderFlag", key: Model.FOLDER_KINDS[k][0], label: Model.FOLDER_KINDS[k][1] })
    out.push({ kind: "header", title: "What it leaves out", note: "" })
    var leaves = [["excludeMuted", "Muted chats"], ["excludeRead", "Read chats"], ["excludeArchived", "Archived chats"]]
    for (var l = 0; l < leaves.length; l++) out.push({ kind: "folderFlag", key: leaves[l][0], label: leaves[l][1] })
    var lists = [["included", "Always in it", "Enter on a chat takes it out"], ["excluded", "Never in it", "Enter on a chat takes it off this list"]]
    for (var i = 0; i < lists.length; i++) {
      out.push({ kind: "header", title: lists[i][1], note: lists[i][2] })
      var ids = Model.toList(f[lists[i][0]])
      for (var j = 0; j < ids.length; j++) out.push({ kind: "folderChat", list: lists[i][0], chatId: ids[j] })
      out.push({ kind: "folderAdd", list: lists[i][0], label: "Add a chat…" })
    }
    out.push({ kind: "header", title: "", note: "" }, { kind: "folderSave", label: f.id ? "Save the folder" : "Create the folder" })
    if (f.id) out.push({ kind: "folderDelete", label: "Delete the folder" })
    return out
  }

  function openFolder(folder) {
    settings.cancelEditing()
    settings.error = ""
    var copy = Model.newFolder()
    if (folder) for (var key in copy) if (folder[key] !== undefined) copy[key] = Model.isList(folder[key]) ? Model.toList(folder[key]).slice() : folder[key]
    settings.folderOpen = copy
    settings.cursor = 1
    list.positionViewAtBeginning()
  }

  function closeFolder() {
    settings.cancelEditing()
    settings.folderOpen = null
    settings.cursor = 1
  }

  // The folder being edited, changed: a new object, so the rows see it.
  function changeFolder(change) {
    var next = {}
    for (var key in settings.folderOpen) next[key] = settings.folderOpen[key]
    for (var c in change) next[c] = change[c]
    settings.folderOpen = next
  }

  function startEditingFolderName() {
    settings.error = ""
    settings.editing = { field: "folderName", label: "The folder's name, up to 12 characters" }
    editor.text = settings.folderOpen.name || ""
    editor.forceActiveFocus()
  }

  function startAddingChat(listName) {
    settings.pickerFor = listName
    chatPicker.open(0, [])
  }

  // A chat goes on one list and off the other: a chat cannot be both always and never in a folder.
  function addFolderChat(chatId) {
    var f = settings.folderOpen
    if (!f || !settings.pickerFor) return
    var other = settings.pickerFor === "included" ? "excluded" : "included"
    var change = {}
    change[settings.pickerFor] = Model.toList(f[settings.pickerFor]).filter(function (id) { return id !== chatId }).concat([chatId])
    change[other] = Model.toList(f[other]).filter(function (id) { return id !== chatId })
    settings.changeFolder(change)
    settings.forceActiveFocus()
  }

  function removeFolderChat(listName, chatId) {
    var change = {}
    change[listName] = Model.toList(settings.folderOpen[listName]).filter(function (id) { return id !== chatId })
    if (listName === "included") change.pinned = Model.toList(settings.folderOpen.pinned).filter(function (id) { return id !== chatId })
    settings.changeFolder(change)
  }

  function saveFolder() {
    var f = settings.folderOpen
    var problem = Model.folderProblem(f)
    if (problem !== "") { settings.error = problem; return }
    var args = {}
    for (var key in f) if (key !== "id" && key !== "icon") args[key] = f[key]
    args.name = String(f.name).trim()
    if (f.icon) args.icon = f.icon
    if (f.id) args.id = f.id
    settings.app.request("folder.save", args, function (answer) {
      if (!answer.ok) { settings.error = answer.error || "Telegram did not take the folder"; return }
      settings.closeFolder()
      settings.loadFolders()
    })
  }

  function askDeleteFolder() {
    var f = settings.folderOpen
    if (!f || !f.id) return
    settings.ask("Delete the folder “" + f.name + "”? The chats in it stay where they are.", function () {
      settings.app.request("folder.delete", { id: f.id }, function (answer) {
        if (!answer.ok) { settings.error = answer.error || "Could not delete the folder"; return }
        settings.closeFolder()
        settings.loadFolders()
      })
    })
  }

  function moveFolder(folderId, delta) {
    var ids = settings.folders.map(function (f) { return f.id })
    var moved = Model.movedFolders(ids, folderId, delta)
    if (moved.join(",") === ids.join(",")) return
    settings.app.request("folders.reorder", { ids: moved }, function (answer) {
      if (!answer.ok) settings.error = answer.error || "Could not move the folder"
      settings.loadFolders()
    })
  }

  FileDialog {
    id: photoDialog
    title: "Your new profile photo"
    fileMode: FileDialog.OpenFile
    nameFilters: ["Pictures (*.jpg *.jpeg *.png *.webp *.gif *.bmp)"]
    onAccepted: settings.setPhoto(settings.urlToPath(selectedFile))
    onRejected: settings.forceActiveFocus()
  }

  // Choosing a chat for a folder: the forward picker, with a title of its own.
  ForwardPicker {
    id: chatPicker
    anchors.fill: parent
    app: settings.app
    chats: settings.app && settings.app.chats ? settings.app.chats : []
    title: settings.pickerFor === "excluded" ? "A chat never in the folder" : "A chat always in the folder"
    onPicked: function (chatId, title) { settings.addFolderChat(chatId) }
    onDismissed: settings.forceActiveFocus()
  }

  // ---------------------------------------------------------------- proxies

  property var proxies: []           // what proxies.list said: never a password or secret
  property var proxyPings: ({})      // proxy id -> { seconds } or { error: true }

  function loadProxies() {
    settings.app.request("proxies.list", {}, function (answer) {
      if (!answer.ok) return
      settings.proxies = answer.result.proxies || []
      settings.proxies.forEach(function (p) { settings.pingProxy(p.id) })
    })
  }

  function pingProxy(id) {
    settings.app.request("proxy.ping", { id: id }, function (answer) {
      var pings = Object.assign({}, settings.proxyPings)
      pings[id] = answer.ok ? { seconds: answer.result.seconds } : { error: true }
      settings.proxyPings = pings
    })
  }

  // Enter on a proxy: use it, or stop using it.
  function toggleProxy(proxy) {
    settings.error = ""
    settings.app.request(proxy.enabled ? "proxy.disable" : "proxy.enable", proxy.enabled ? {} : { id: proxy.id }, function (answer) {
      if (!answer.ok) settings.error = answer.error || "Telegram did not take the change"
      settings.loadProxies()
    })
  }

  function askRemoveProxy(proxy) {
    settings.ask("Remove the proxy " + proxy.server + ":" + proxy.port + "?", function () {
      settings.app.request("proxy.remove", { id: proxy.id }, function (answer) {
        if (!answer.ok) settings.error = answer.error || "Telegram did not take the change"
        settings.loadProxies()
      })
    })
  }

  // A proxy is added one field at a time in the bar above the list, as two-step verification is changed.
  function startProxyFlow(kind) {
    settings.error = ""
    settings.confirm = null
    settings.flow = { kind: "proxy", proxyType: kind, steps: Model.proxySteps(kind), step: 0, values: {} }
    settings.showFlowStep()
  }

  function addProxy(kind, values) {
    var args
    if (kind === "link") {
      args = { link: Model.proxyLinkUrl(values.link) }
    } else {
      var address = Model.parseProxyAddress(values.address)
      args = { type: kind, server: address.server, port: address.port }
      if (kind === "mtproto") args.secret = values.secret.trim()
      else { args.username = values.username || ""; args.password = values.password || "" }
    }
    settings.app.request(kind === "link" ? "proxy.addLink" : "proxy.add", args, function (answer) {
      if (!answer.ok) settings.error = answer.error || "Telegram did not take the proxy"
      settings.loadProxies()
    })
  }

  // ---------------------------------------------------------------- the account

  function ask(text, run) {
    settings.error = ""
    settings.confirm = { text: text, run: run }
  }

  function answer(yes) {
    var question = settings.confirm
    settings.confirm = null
    if (yes && question) question.run()
  }

  function activate(row) {
    if (!row) return
    if (row.kind === "profileField") {
      settings.startEditing(row)
    } else if (row.kind === "profilePhoto") {
      settings.error = ""
      photoDialog.open()
    } else if (row.kind === "profilePhone") {
      settings.error = "Your phone number is changed in Telegram's app on your phone."
    } else if (row.kind === "privacy") {
      settings.changePrivacy(row)
    } else if (row.kind === "blocked") {
      settings.blockedOpen = !settings.blockedOpen
      if (settings.blockedOpen) settings.loadBlocked()
    } else if (row.kind === "blockedSender") {
      settings.askUnblock(row.sender)
    } else if (row.kind === "password") {
      settings.startPasswordFlow(settings.password && settings.password.hasPassword ? "change" : "on")
    } else if (row.kind === "passwordOff") {
      settings.ask("Turn two-step verification off? Signing in on a new device then takes only the code Telegram sends.",
                   function () { settings.startPasswordFlow("off") })
    } else if (row.kind === "passwordCode") {
      settings.startPasswordFlow("code")
    } else if (row.kind === "accountTtl") {
      settings.changeAccountTtl()
    } else if (row.kind === "autoDelete") {
      settings.changeDefaultAutoDelete()
    } else if (row.kind === "proxy") {
      settings.toggleProxy(row.proxy)
    } else if (row.kind === "proxyAdd") {
      settings.startProxyFlow(row.type)
    } else if (row.kind === "reactionsSeen") {
      settings.app.request("settings.reactions", { seen: !settings.app.reactionsSeen }, function (answer) {
        if (!answer.ok) settings.error = answer.error || "The setting could not be saved"
      })
    } else if (row.kind === "sound") {
      settings.app.request("settings.sounds", { style: Model.nextSoundStyle(settings.app.soundStyle) }, function (answer) {
        if (!answer.ok) settings.error = answer.error || "The setting could not be saved"
      })
    } else if (row.kind === "soundHear") {
      settings.app.request("sounds.play", { userId: settings.app.meId }, function () {})
    } else if (row.kind === "scope") {
      settings.changeScope(row.id, { muted: !(settings.scopes[row.id] && settings.scopes[row.id].muted) })
    } else if (row.kind === "previews") {
      settings.togglePreviews()
    } else if (row.kind === "download") {
      settings.app.setAutoDownload(Model.nextDownloadRule(settings.app.autoDownloadRules, row.id))
    } else if (row.kind === "folder") {
      settings.openFolder(row.folder)
    } else if (row.kind === "newFolder") {
      settings.openFolder(null)
    } else if (row.kind === "folderName") {
      settings.startEditingFolderName()
    } else if (row.kind === "folderFlag") {
      var flag = {}
      flag[row.key] = !settings.folderOpen[row.key]
      settings.changeFolder(flag)
    } else if (row.kind === "folderChat") {
      settings.removeFolderChat(row.list, row.chatId)
    } else if (row.kind === "folderAdd") {
      settings.startAddingChat(row.list)
    } else if (row.kind === "folderSave") {
      settings.saveFolder()
    } else if (row.kind === "folderDelete") {
      settings.askDeleteFolder()
    } else if (row.kind === "storage") {
      settings.ask("Clear the cache? Downloaded photos, videos and files are deleted from this computer; they download again when you open them.", function () {
        settings.app.request("storage.clear", {}, function (answer) {
          if (!answer.ok) { settings.error = answer.error || "The cache could not be cleared"; return }
          settings.app.clearFileStates()
          settings.loadStorage()
        })
      })
    } else if (row.kind === "sessions") {
      settings.sessionsOpen = !settings.sessionsOpen
      if (settings.sessionsOpen) settings.loadSessions()
    } else if (row.kind === "session") {
      if (row.session.current) { settings.error = "That is this computer: to sign out here, use the last row of the account."; return }
      settings.ask("Sign out " + Model.sessionTitle(row.session) + (row.session.device ? " on " + row.session.device : "") + "?", function () {
        settings.app.request("session.terminate", { id: row.session.id }, function (answer) {
          if (!answer.ok) settings.error = answer.error || "That device could not be signed out"
          settings.loadSessions()
        })
      })
    } else if (row.kind === "otherSessions") {
      settings.ask("Sign out every device except this computer?", function () {
        settings.app.request("sessions.terminateOthers", {}, function (answer) {
          if (!answer.ok) settings.error = answer.error || "The other devices could not be signed out"
          settings.loadSessions()
        })
      })
    } else if (row.kind === "logout") {
      settings.ask("Sign out of Telegram here? Your chats stay on Telegram; what Omagram keeps on this computer is removed.", function () {
        settings.app.request("auth.logout", {}, function (answer) {
          if (!answer.ok) settings.error = answer.error || "Could not sign out"
          else settings.closed()
        })
      })
    } else if (settings.editable(row)) {
      settings.startRecording(false)
    }
  }

  Keys.onPressed: function (event) {
    if (settings.recording !== "") {
      settings.capture(event)
      event.accepted = true
      return
    }
    var key = event.key
    if (settings.editing) {   // the field being changed has the keys; nothing else moves meanwhile
      if (key === Qt.Key_Escape) settings.cancelEditing()
      event.accepted = true
      return
    }
    if (settings.confirm) {
      if (key === Qt.Key_Return || key === Qt.Key_Enter) settings.answer(true)
      else if (key === Qt.Key_Escape) settings.answer(false)
      event.accepted = true   // nothing else happens while a question waits
      return
    }
    if (key === Qt.Key_Escape) { if (settings.folderOpen) settings.closeFolder(); else settings.closed() }
    else if (key === Qt.Key_Down || key === Qt.Key_J) settings.move(1)
    else if (key === Qt.Key_Up || key === Qt.Key_K) settings.move(-1)
    else if (key === Qt.Key_PageDown) settings.move(8)
    else if (key === Qt.Key_PageUp) settings.move(-8)
    else if (key === Qt.Key_Return || key === Qt.Key_Enter) settings.activate(settings.current)
    else if (key === Qt.Key_A) settings.startRecording(true)
    else if (key === Qt.Key_Backspace || key === Qt.Key_Delete) settings.removeLast()
    else if (key === Qt.Key_R) settings.reset()
    else if ((key === Qt.Key_BracketLeft || key === Qt.Key_BracketRight) && settings.current && settings.current.kind === "folder")
      settings.moveFolder(settings.current.folder.id, key === Qt.Key_BracketLeft ? -1 : 1)
    else return
    event.accepted = true
  }

  Rectangle {
    anchors.fill: parent
    color: settings.app.background
  }

  MouseArea { anchors.fill: parent }

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: Style.space(24)
    spacing: Style.space(10)

    RowLayout {
      Layout.fillWidth: true

      Column {
        Layout.fillWidth: true
        spacing: Style.space(4)
        Text {
          text: "Settings"
          color: settings.app.foreground
          font.family: settings.app.fontFamily
          font.pixelSize: Style.font.displayLarge
          font.bold: true
        }
        Text {
          text: "↑↓ choose  ·  Enter open or change  ·  A add a key  ·  Backspace remove  ·  R reset  ·  Esc close"
          color: settings.app.muted
          font.family: settings.app.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // md-close (U+F0156)
      Text {
        text: String.fromCodePoint(0xF0156)
        color: closeArea.containsMouse ? settings.app.foreground : settings.app.muted
        font.family: settings.app.glyphFamily
        font.pixelSize: Style.font.title
        MouseArea {
          id: closeArea
          anchors.fill: parent
          anchors.margins: -Style.space(6)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: settings.closed()
        }
      }
    }

    // A question about the account, before anything is changed.
    Rectangle {
      Layout.fillWidth: true
      visible: !!settings.confirm
      Layout.preferredHeight: visible ? Math.max(Style.space(46), confirmText.implicitHeight + Style.space(20)) : 0
      radius: Style.cornerRadius
      color: Qt.rgba(settings.app.urgent.r, settings.app.urgent.g, settings.app.urgent.b, 0.1)
      border.width: 1
      border.color: settings.app.urgent

      Text {
        id: confirmText
        anchors.left: parent.left
        anchors.right: confirmButtons.left
        anchors.leftMargin: Style.space(14)
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
        text: settings.confirm ? settings.confirm.text : ""
        color: settings.app.foreground
        font.family: settings.app.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Row {
        id: confirmButtons
        anchors.right: parent.right
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)

        Repeater {
          model: [{ yes: true, label: "Yes   Enter" }, { yes: false, label: "No   Esc" }]
          delegate: Rectangle {
            id: choice
            required property var modelData
            width: choiceLabel.implicitWidth + Style.space(18)
            height: Style.space(28)
            radius: Style.cornerRadius
            color: choiceArea.containsMouse ? Qt.rgba(settings.app.foreground.r, settings.app.foreground.g, settings.app.foreground.b, 0.14)
                 : (choice.modelData.yes ? Qt.rgba(settings.app.urgent.r, settings.app.urgent.g, settings.app.urgent.b, 0.2) : "transparent")
            Text {
              id: choiceLabel
              anchors.centerIn: parent
              text: choice.modelData.label
              color: settings.app.foreground
              font.family: settings.app.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: choice.modelData.yes
            }
            MouseArea {
              id: choiceArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: settings.answer(choice.modelData.yes)
            }
          }
        }
      }
    }

    // A field of your profile being changed: Enter saves it, Esc leaves it as it was.
    Rectangle {
      Layout.fillWidth: true
      visible: !!settings.editing
      Layout.preferredHeight: visible ? editor.implicitHeight + Style.space(24) : 0
      radius: Style.cornerRadius
      color: Qt.rgba(settings.app.accent.r, settings.app.accent.g, settings.app.accent.b, 0.06)
      border.width: 1
      border.color: settings.app.accent

      Field {
        id: editor
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(12)
        app: settings.app
        label: settings.editing ? settings.editing.label + "   ·   Enter saves   ·   Esc cancels" : ""
        placeholder: settings.editing && settings.editing.placeholder ? settings.editing.placeholder
                   : (settings.editing && settings.editing.field === "username" ? "a name people can find you by"
                      : (settings.editing && settings.editing.field === "bio" ? "a few words about you" : ""))
        secret: !!settings.editing && settings.editing.secret === true
        maximumLength: settings.flow ? (settings.flow.kind === "proxy" ? 2048 : 256) : (settings.editing && settings.editing.field === "bio" ? 140 : 64)
        error: !settings.editing ? "" : (settings.flow ? settings.editorError : Model.profileProblem(settings.editing.field, editor.text))
        onAccepted: settings.saveEditing()
        Keys.onEscapePressed: settings.cancelEditing()
      }
    }

    Text {
      Layout.fillWidth: true
      visible: settings.error !== ""
      text: settings.error
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      color: settings.app.urgent
      font.family: settings.app.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    ListView {
      id: list
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      model: settings.rows
      boundsBehavior: Flickable.StopAtBounds

      WheelScroll { view: list }

      delegate: Rectangle {
        id: row
        required property var modelData
        required property int index
        readonly property bool header: modelData.kind === "header"
        readonly property bool account: settings.accountKinds.indexOf(modelData.kind) >= 0
        readonly property bool isCursor: index === settings.cursor
        readonly property bool isRecording: settings.editable(modelData) && settings.recording === modelData.id
        readonly property var keys: settings.keysOf(modelData)
        readonly property var clashes: modelData.kind === "action" ? Keymap.conflictsFor(settings.overrides, modelData.id) : []

        width: list.width
        height: header ? Style.space(modelData.note ? 58 : 44)
              : (account ? Style.space(modelData.kind === "profilePhoto" ? 66
                                       : (["session", "storage", "profileField", "profilePhone", "privacy", "blocked", "password", "accountTtl", "autoDelete", "proxy", "reactionsSeen", "sound",
                                           "scope", "previews", "download", "folder", "folderName", "folderFlag"]
                                            .indexOf(modelData.kind) >= 0 ? 58 : 44))
                         : Style.space(clashes.length || modelData.kind === "global" ? 58 : 42))
        radius: Style.cornerRadius
        color: row.isCursor && !row.header ? settings.app.selected
             : (rowArea.containsMouse && !row.header ? Qt.rgba(settings.app.foreground.r, settings.app.foreground.g, settings.app.foreground.b, 0.04) : "transparent")

        Column {
          visible: row.header
          anchors.left: parent.left
          anchors.bottom: parent.bottom
          anchors.leftMargin: Style.space(4)
          anchors.bottomMargin: Style.space(6)
          spacing: Style.space(2)
          Text {
            text: row.modelData.title || ""
            color: settings.app.foreground
            font.family: settings.app.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
          Text {
            visible: !!row.modelData.note
            text: row.modelData.note || ""
            color: settings.app.muted
            font.family: settings.app.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ---------------------------------------------- account rows
        ColumnLayout {
          visible: row.account
          anchors.fill: parent
          anchors.leftMargin: Style.space(["session", "blockedSender", "folderChat"].indexOf(row.modelData.kind) >= 0 ? 30 : 14)
          anchors.rightMargin: Style.space(14)
          anchors.topMargin: Style.space(6)
          anchors.bottomMargin: Style.space(6)
          spacing: Style.space(2)

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            Avatar {
              visible: row.modelData.kind === "profilePhoto"
              app: settings.app
              chat: settings.profileChat
              size: Style.space(40)
              Layout.preferredWidth: size
              Layout.preferredHeight: size
            }

            Text {
              Layout.fillWidth: true
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: row.modelData.kind === "session" ? Model.sessionTitle(row.modelData.session)
                  : row.modelData.kind === "blockedSender" ? row.modelData.sender.name
                  : row.modelData.kind === "folderChat" ? (Model.chatTitle(Model.findChat(settings.app.chats || [], row.modelData.chatId), settings.app.meId)
                                                           || "A chat that is in none of your lists")
                  : row.modelData.label + (row.modelData.kind === "sessions" && settings.sessions.length ? "  (" + settings.sessions.length + ")" : "")
              color: ["logout", "otherSessions", "passwordOff", "folderDelete"].indexOf(row.modelData.kind) >= 0 ? settings.app.urgent : settings.app.foreground
              font.family: settings.app.fontFamily
              font.pixelSize: ["session", "blockedSender", "folderChat"].indexOf(row.modelData.kind) >= 0 ? Style.font.bodySmall : Style.font.body
            }
            Text {
              textFormat: Text.PlainText
              text: ({ profileField: "Enter changes it", privacy: "Enter changes it", accountTtl: "Enter changes it", autoDelete: "Enter changes it", proxy: "Enter uses it or stops", proxyAdd: "Enter", reactionsSeen: "Enter changes it", sound: "Enter changes it", soundHear: "Enter plays it",
                       scope: "Enter changes it", previews: "Enter changes it", download: "Enter changes it",
                       folder: "Enter opens it", newFolder: "Enter", folderName: "Enter changes it", folderFlag: "Enter changes it",
                       folderChat: "Enter takes it off", folderAdd: "Enter", folderSave: "Enter", folderDelete: "Enter",
                       blocked: settings.blockedOpen ? "Enter hides them" : "Enter shows them", blockedSender: "Enter unblocks",
                       password: settings.password && settings.password.hasPassword ? "Enter changes the password" : "Enter turns it on",
                       passwordOff: "Enter", passwordCode: "Enter",
                       profilePhoto: settings.profile && (settings.profile.photo || settings.profile.photoId)
                                     ? "Enter changes it  ·  Backspace removes it" : "Enter sets one",
                       storage: "Enter clears the cache", sessions: settings.sessionsOpen ? "Enter hides them" : "Enter shows them",
                       session: row.modelData.session && row.modelData.session.current ? "this computer" : "Enter signs it out",
                       otherSessions: "Enter", logout: "Enter" })[row.modelData.kind] || ""
              color: settings.app.muted
              font.family: settings.app.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            Layout.fillWidth: true
            visible: text !== ""
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: row.modelData.kind === "storage" ? Model.storageText(settings.storage)
                : row.modelData.kind === "session" ? Model.sessionDetail(row.modelData.session, settings.nowMs)
                : row.modelData.kind === "profileField" ? Model.profileValue(settings.profile, row.modelData.field)
                : row.modelData.kind === "profilePhone" ? Model.profileValue(settings.profile, "phone")
                : row.modelData.kind === "privacy" ? Model.privacyText(settings.privacy[row.modelData.id])
                : row.modelData.kind === "blocked" ? Model.blockedText(settings.blocked)
                : row.modelData.kind === "password" ? Model.passwordText(settings.password)
                : row.modelData.kind === "accountTtl" ? Model.ttlText(settings.accountTtl)
                : row.modelData.kind === "autoDelete" ? (settings.defaultAutoDelete < 0 ? "Loading…" : Model.autoDeleteText(settings.defaultAutoDelete))
                : row.modelData.kind === "proxy" ? Model.proxyText(row.modelData.proxy, settings.proxyPings[row.modelData.proxy.id], settings.app.connection)
                : row.modelData.kind === "reactionsSeen" ? (settings.app.reactionsSeen ? "Seen when you open the chat" : "Kept until you scroll to them")
                : row.modelData.kind === "sound" ? Model.soundStyleText(settings.app.soundStyle)
                : row.modelData.kind === "scope" ? Model.scopeText(settings.scopes[row.modelData.id])
                : row.modelData.kind === "previews" ? Model.previewsText(settings.scopes)
                : row.modelData.kind === "download" ? Model.downloadText(settings.app.autoDownloadRules, row.modelData.id)
                : row.modelData.kind === "folder" ? Model.folderSummary(row.modelData.folder)
                : row.modelData.kind === "folderName" ? (settings.folderOpen && settings.folderOpen.name ? settings.folderOpen.name : "None yet")
                : row.modelData.kind === "folderFlag" ? (settings.folderOpen && settings.folderOpen[row.modelData.key] ? "Yes" : "No")
                : row.modelData.kind === "profilePhoto" ? (settings.photoBusy ? "Setting your new photo…" : Model.profileValue(settings.profile, "photo"))
                : ""
            color: settings.app.muted
            font.family: settings.app.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ---------------------------------------------- shortcuts
        ColumnLayout {
          visible: !row.header && !row.account
          anchors.fill: parent
          anchors.leftMargin: Style.space(14)
          anchors.rightMargin: Style.space(14)
          anchors.topMargin: Style.space(6)
          anchors.bottomMargin: Style.space(6)
          spacing: Style.space(2)

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            Text {
              Layout.fillWidth: true
              text: row.modelData.label || ""
              elide: Text.ElideRight
              color: settings.app.foreground
              font.family: settings.app.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              visible: settings.changed(row.modelData) && !row.isRecording
              text: row.modelData.kind === "global" ? "" : "changed"
              color: settings.app.muted
              font.family: settings.app.fontFamily
              font.pixelSize: Style.font.caption
            }

            Rectangle {
              visible: row.isRecording
              implicitWidth: recordingText.implicitWidth + Style.space(16)
              implicitHeight: Style.space(26)
              radius: Style.cornerRadius
              color: Qt.rgba(settings.app.urgent.r, settings.app.urgent.g, settings.app.urgent.b, 0.15)
              border.width: 1
              border.color: settings.app.urgent
              Text {
                id: recordingText
                anchors.centerIn: parent
                text: settings.recordingAdds ? "Press the key to add  ·  Esc cancels" : "Press the new keys  ·  Esc cancels"
                color: settings.app.foreground
                font.family: settings.app.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Repeater {
              model: row.isRecording ? [] : row.keys
              delegate: Rectangle {
                required property var modelData
                implicitWidth: chip.implicitWidth + Style.space(14)
                implicitHeight: Style.space(26)
                radius: Style.cornerRadius
                color: Qt.rgba(settings.app.foreground.r, settings.app.foreground.g, settings.app.foreground.b, 0.08)
                border.width: 1
                border.color: Qt.rgba(settings.app.foreground.r, settings.app.foreground.g, settings.app.foreground.b, 0.18)
                Text {
                  id: chip
                  anchors.centerIn: parent
                  text: row.modelData.kind === "global" ? modelData : Keymap.label(modelData)
                  textFormat: Text.PlainText
                  color: settings.app.foreground
                  font.family: settings.app.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Text {
              visible: !row.isRecording && row.keys.length === 0
              text: row.modelData.kind === "global" ? "Not set" : "Off"
              color: settings.app.muted
              font.family: settings.app.fontFamily
              font.pixelSize: Style.font.caption
              font.italic: true
            }
          }

          Text {
            visible: row.modelData.kind === "global" && !!settings.globals[row.modelData.id]
            text: settings.statusText(row.modelData.id)
            color: (settings.globalStatus[row.modelData.id] || "") === "active" ? settings.app.muted : settings.app.urgent
            font.family: settings.app.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            Layout.fillWidth: true
            visible: row.clashes.length > 0
            elide: Text.ElideRight
            color: settings.app.urgent
            font.family: settings.app.fontFamily
            font.pixelSize: Style.font.caption
            text: {
              var names = []
              for (var i = 0; i < row.clashes.length; i++) {
                for (var j = 0; j < row.clashes[i].ids.length; j++) {
                  var other = row.clashes[i].ids[j]
                  if (other === row.modelData.id) continue
                  var action = Keymap.actionById(other)
                  var section = Keymap.sectionOf(other)
                  names.push(Keymap.label(row.clashes[i].sequence) + " is also " + (action ? action.label : other)
                             + (section ? " (" + section.title + ")" : ""))
                }
              }
              return names.join("  ·  ")
            }
          }
        }

        MouseArea {
          id: rowArea
          anchors.fill: parent
          enabled: !row.header
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          cursorShape: Qt.PointingHandCursor
          onClicked: function (mouse) {
            settings.cursor = row.index
            settings.forceActiveFocus()
            if (row.account) settings.activate(row.modelData)
            else if (mouse.button === Qt.RightButton) settings.reset()
            else settings.startRecording(false)
          }
        }
      }
    }
  }
}
