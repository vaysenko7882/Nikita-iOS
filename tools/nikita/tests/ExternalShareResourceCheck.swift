import Foundation

// Controlled producers stand in for MediaBox/network. The exercised collector
// and SwiftSignalKit subscriber/disposal code are the actual production sources.
private struct MediaResourceData { let complete: Bool }
private struct MediaResourceReference { let resource = 1 }
private enum MediaResourceStatsCategory { case generic }
private enum MediaResourceUserLocation { case other }
private enum MediaResourceUserContentType { case other }
private enum ResourceDataOption { case complete(waitUntilFetchStatus: Bool) }
private enum FetchSource { case remote }
private enum FetchError { case unavailable }

private final class MediaBox {
    var local = false
    var failDuringStart = false
    var dataDisposed = 0
    var fetchDisposed = 0
    var fetchStarts = 0
    var reportedErrors = false
    var dataSubscriber: Subscriber<MediaResourceData, NoError>?
    var fetchSubscriber: Subscriber<FetchSource, FetchError>?

    func resourceData(_ resource: Int, option: ResourceDataOption) -> Signal<MediaResourceData, NoError> {
        return Signal { subscriber in
            self.dataSubscriber = subscriber
            subscriber.putNext(MediaResourceData(complete: self.local))
            return ActionDisposable { self.dataDisposed += 1 }
        }
    }
}

private final class Postbox { let mediaBox = MediaBox() }

private func fetchedMediaResource(mediaBox: MediaBox, userLocation: MediaResourceUserLocation,
    userContentType: MediaResourceUserContentType, reference: MediaResourceReference,
    statsCategory: MediaResourceStatsCategory, reportResultStatus: Bool = false) -> Signal<FetchSource, FetchError> {
    return Signal { subscriber in
        mediaBox.fetchStarts += 1
        mediaBox.reportedErrors = reportResultStatus
        mediaBox.fetchSubscriber = subscriber
        if mediaBox.failDuringStart { subscriber.putError(.unavailable) }
        return ActionDisposable { mediaBox.fetchDisposed += 1 }
    }
}

@main private enum ExternalShareResourceCheck {
    static func main() {
        for scenario in ["local", "start failure", "late failure", "complete then error", "cancel"] {
            let postbox = Postbox()
            postbox.mediaBox.local = scenario == "local"
            postbox.mediaBox.failDuringStart = scenario == "start failure"
            var states: [String] = []
            var completions = 0
            let disposable = collectExternalShareResource(postbox: postbox, resourceReference: MediaResourceReference(), statsCategory: .generic)
                .start(next: { state in
                    switch state {
                    case .progress: states.append("progress")
                    case .failed: states.append("failed")
                    case .done: states.append("done")
                    }
                }, completed: { completions += 1 })
            switch scenario {
            case "local":
                precondition(states == ["done"] && postbox.mediaBox.fetchStarts == 0)
            case "start failure":
                precondition(states == ["progress", "failed"])
            case "late failure":
                postbox.mediaBox.fetchSubscriber?.putError(.unavailable)
                postbox.mediaBox.dataSubscriber?.putNext(MediaResourceData(complete: true))
                precondition(states == ["progress", "failed"], "A failed resource must not report success later")
            case "complete then error":
                postbox.mediaBox.dataSubscriber?.putNext(MediaResourceData(complete: true))
                postbox.mediaBox.fetchSubscriber?.putError(.unavailable)
                postbox.mediaBox.dataSubscriber?.putNext(MediaResourceData(complete: true))
                precondition(states == ["progress", "done"], "A completed resource must emit once")
            default:
                disposable.dispose()
                postbox.mediaBox.fetchSubscriber?.putError(.unavailable)
                postbox.mediaBox.dataSubscriber?.putNext(MediaResourceData(complete: true))
                precondition(states == ["progress"] && completions == 0)
            }
            if scenario != "cancel" { precondition(completions == 1) }
            disposable.dispose()
            precondition(postbox.mediaBox.dataDisposed == 1)
            precondition(postbox.mediaBox.fetchDisposed == (scenario == "local" ? 0 : 1))
            if scenario != "local" { precondition(postbox.mediaBox.reportedErrors) }
        }
        print("External share: local data, immediate/delayed failure, completion/error races and cancellation passed using production collector and signals.")
    }
}
