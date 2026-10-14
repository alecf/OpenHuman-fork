import Foundation
import MailModel
import MailRender
import Synchronization

public actor RenderQueue {
    private struct CacheKey: Hashable {
        let key: RenderCacheKey
        let contentHash: Int
    }

    public nonisolated let settings: (any SettingsPort)?
    private nonisolated let current: Mutex<MessageRenderer>
    private var cache: BoundedLRU<CacheKey, RenderedBody>
    public private(set) var renderCount = 0
    public private(set) var skippedCancelled = 0
    public var cachedBytes: Int { cache.totalCost }
    public var cachedCount: Int { cache.count }

    public static let defaultByteLimit = 64 * 1_048_576

    public init(renderer: MessageRenderer = MessageRenderer(), capacity: Int = 200,
                byteLimit: Int = RenderQueue.defaultByteLimit, settings: (any SettingsPort)? = nil) {
        current = Mutex(renderer)
        cache = BoundedLRU(countLimit: capacity, costLimit: byteLimit)
        self.settings = settings
    }

    public nonisolated var renderer: MessageRenderer { current.withLock { $0 } }

    public nonisolated func setRenderer(_ renderer: MessageRenderer) {
        current.withLock { $0 = renderer }
    }

    public func render(_ content: MessageContent, for key: MessageKey, context: RenderContext = RenderContext(),
                       renderer: MessageRenderer? = nil) -> RenderedBody {
        let renderer = renderer ?? self.renderer
        var hasher = Hasher()
        hasher.combine(content.html)
        hasher.combine(content.text)
        let cacheKey = CacheKey(key: renderer.cacheKey(for: key, context: context), contentHash: hasher.finalize())
        if let hit = cache.value(for: cacheKey) { return hit }
        let rendered = renderer.render(content, context: context)
        renderCount += 1
        cache.insert(rendered, for: cacheKey, cost: rendered.approximateBytes)
        return rendered
    }

    public func renderUnlessCancelled(_ content: MessageContent, for key: MessageKey, context: RenderContext = RenderContext(),
                                      renderer: MessageRenderer? = nil) -> RenderedBody? {
        if Task.isCancelled, !isCached(content, for: key, context: context, renderer: renderer ?? self.renderer) {
            skippedCancelled += 1
            return nil
        }
        return render(content, for: key, context: context, renderer: renderer)
    }

    public func isCached(_ content: MessageContent, for key: MessageKey, context: RenderContext,
                         renderer: MessageRenderer) -> Bool {
        var hasher = Hasher()
        hasher.combine(content.html)
        hasher.combine(content.text)
        return cache.contains(CacheKey(key: renderer.cacheKey(for: key, context: context), contentHash: hasher.finalize()))
    }
}
