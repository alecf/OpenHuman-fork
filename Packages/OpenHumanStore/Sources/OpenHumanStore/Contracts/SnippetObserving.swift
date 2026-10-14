import Foundation
import OpenHumanCore

public protocol SnippetObserving: Sendable {
    func observeSnippets(account: AccountID?) -> StoreObservation<[SnippetItem]>
}
