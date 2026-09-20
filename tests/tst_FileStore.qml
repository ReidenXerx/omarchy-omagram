import QtQuick
import QtTest
import "../app"

TestCase {
  name: "FileStore"

  Component {
    id: fileStore
    FileStore {}
  }

  function test_updatesOnlyMatchingFile() {
    var store = fileStore.createObject(null)
    verify(store !== null)

    var first = store.state({ id: 1, size: 100, downloaded: 0, active: false, path: "" })
    var second = store.state({ id: 2, size: 200, downloaded: 0, active: false, path: "" })
    var firstChanges = 0
    var secondChanges = 0
    first.pathChanged.connect(function () { firstChanges++ })
    second.pathChanged.connect(function () { secondChanges++ })

    store.update({ id: 1, size: 100, downloaded: 100, active: false, path: "/tmp/one" })
    store.update({ id: 3, size: 300, downloaded: 300, active: false, path: "/tmp/three" })
    var third = store.state({ id: 3, size: 0, downloaded: 0, active: false, path: "" })

    compare(store.state({ id: 1 }), first)
    compare(first.path, "/tmp/one")
    compare(firstChanges, 1)
    compare(second.path, "")
    compare(secondChanges, 0)
    compare(third.path, "/tmp/three")
    store.destroy()
  }
}
