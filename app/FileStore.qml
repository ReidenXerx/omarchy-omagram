import QtQuick

// Observable file state by id. Updating one download wakes only bindings that use that file,
// instead of every avatar and media delegate in the application.
QtObject {
  id: store

  property var states: ({})
  property var latest: ({})
  property int epoch: 0

  property Component stateFactory: Component {
    QtObject {
      property real fileId: 0
      property real size: 0
      property real downloaded: 0
      property bool active: false
      property string path: ""

      function apply(view) {
        fileId = Number(view.id) || 0
        size = Math.max(0, Number(view.size) || 0)
        downloaded = Math.max(0, Number(view.downloaded) || 0)
        active = view.active === true
        path = typeof view.path === "string" ? view.path : ""
      }
    }
  }

  function state(file) {
    store.epoch
    if (!file || !(Number(file.id) > 0)) return null
    var id = Number(file.id)
    var known = store.states[id]
    if (known) return known
    known = store.stateFactory.createObject(store)
    if (!known) return null
    known.apply(store.latest[id] || file)
    store.states[id] = known
    return known
  }

  function update(view) {
    if (!view || !(Number(view.id) > 0)) return
    var id = Number(view.id)
    store.latest[id] = view
    var known = store.states[id]
    if (known) known.apply(view)
  }

  function clear() {
    var old = store.states
    store.states = ({})
    store.latest = ({})
    store.epoch++
    Qt.callLater(function () {
      for (var id in old) if (old[id]) old[id].destroy()
    })
  }
}
