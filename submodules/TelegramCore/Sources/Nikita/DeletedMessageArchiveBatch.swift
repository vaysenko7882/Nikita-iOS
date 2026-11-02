import Foundation

/// One replay transaction may refresh thousands of messages. Decode shared
/// archive preferences once, mutate the same index, and persist/trim once before
/// that transaction returns. Nothing is deferred past the Postbox transaction.
final class DeletedMessageArchiveBatch {
    private let loadSettings: () -> DeletedMessageArchiveSettings?
    private let loadIndex: () -> DeletedMessageArchiveIndex
    private let saveIndex: (DeletedMessageArchiveIndex) -> Void
    private let loadRemoteState: () -> NikitaRemoteArchiveState?
    private let saveRemoteState: (NikitaRemoteArchiveState) -> Void
    private let retainMedia: (DeletedMessageArchiveSettings, DeletedMessageArchiveIndex) -> Void
    private var settingsLoaded = false
    private var settingsValue: DeletedMessageArchiveSettings?
    private var indexLoaded = false
    private var indexValue = DeletedMessageArchiveIndex.empty
    private var indexChanged = false
    private var remoteStateLoaded = false
    private var remoteState: NikitaRemoteArchiveState?
    private var remoteStateChanged = false
    private var retentionNeeded = false
    private var finished = false

    init(loadSettings: @escaping () -> DeletedMessageArchiveSettings?,
         loadIndex: @escaping () -> DeletedMessageArchiveIndex,
         saveIndex: @escaping (DeletedMessageArchiveIndex) -> Void,
         loadRemoteState: @escaping () -> NikitaRemoteArchiveState?,
         saveRemoteState: @escaping (NikitaRemoteArchiveState) -> Void,
         retainMedia: @escaping (DeletedMessageArchiveSettings, DeletedMessageArchiveIndex) -> Void) {
        self.loadSettings = loadSettings; self.loadIndex = loadIndex; self.saveIndex = saveIndex
        self.loadRemoteState = loadRemoteState; self.saveRemoteState = saveRemoteState
        self.retainMedia = retainMedia
    }

    var settings: DeletedMessageArchiveSettings? {
        if !self.settingsLoaded {
            self.settingsValue = self.loadSettings(); self.settingsLoaded = true
        }
        return self.settingsValue
    }
    var index: DeletedMessageArchiveIndex {
        self.ensureIndexLoaded()
        return self.indexValue
    }
    private func ensureIndexLoaded() {
        if !self.indexLoaded {
            let _ = self.settings // Session cleanup must precede the index snapshot.
            self.indexValue = self.loadIndex(); self.indexLoaded = true
        }
    }
    func updateIndex(_ update: (inout DeletedMessageArchiveIndex) -> Void) {
        precondition(!self.finished)
        self.ensureIndexLoaded()
        update(&self.indexValue); self.indexChanged = true
    }
    func takePendingVersions(for key: String) -> [DeletedMessageArchiveIndexEntry]? {
        precondition(!self.finished)
        if !self.remoteStateLoaded {
            self.remoteState = self.loadRemoteState(); self.remoteStateLoaded = true
        }
        guard let versions = self.remoteState?.pendingVersions.removeValue(forKey: key) else { return nil }
        self.remoteStateChanged = true
        return versions
    }
    func requestMediaRetention() {
        precondition(!self.finished)
        self.retentionNeeded = true
    }
    func finish() {
        guard !self.finished else { return }
        self.finished = true
        if self.indexChanged { self.saveIndex(self.indexValue) }
        if self.remoteStateChanged, let state = self.remoteState { self.saveRemoteState(state) }
        if self.retentionNeeded, let settings = self.settings {
            self.retainMedia(settings, self.index)
        }
    }
}
