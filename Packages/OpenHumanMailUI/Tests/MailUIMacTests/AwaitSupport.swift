import Observation
import Testing

let testBackstop: Duration = .seconds(120)

@MainActor
func awaitObserved(_ what: String, sourceLocation: SourceLocation = #_sourceLocation,
                   _ condition: @escaping @MainActor () -> Bool) async {
    if condition() { return }
    let watcher = Task { @MainActor () -> Bool in
        for await holds in Observations({ condition() }) where holds { return true }
        return false
    }
    let backstop = Task { try? await Task.sleep(for: testBackstop); watcher.cancel() } // flake-ok: bounds a hung observation
    let met = await watcher.value
    backstop.cancel()
    if !met { Issue.record("never became true (\(testBackstop) backstop): \(what)", sourceLocation: sourceLocation) }
}
