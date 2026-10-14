#if os(macOS)
import AppKit
import MailTheme
import SwiftUI
import Testing
@testable import MailUI

@MainActor
private final class Seen {
    var accent: ThemeColor?
    var scheme: ColorScheme?
    var renders = 0
    var animated: [(accent: ThemeColor, animates: Bool)] = []
}

private struct Probe: View {
    let seen: Seen
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        seen.accent = theme.accentFill
        seen.scheme = scheme
        seen.renders += 1
        return Button("Continue") {}.buttonStyle(.borderedProminent)
    }
}

private struct SheetLike: View {
    let store: ThemeStore
    let seen: Seen
    var body: some View { Probe(seen: seen).themed(by: store) }
}

private struct AnimationProbe: View {
    let seen: Seen
    @Environment(\.theme) private var theme

    var body: some View {
        let accent = theme.accentFill
        return Rectangle().fill(accent.color).transaction { transaction in
            seen.animated.append((accent, transaction.animation != nil && !transaction.disablesAnimations))
        }
    }
}

@MainActor
private func spin(until condition: @MainActor () -> Bool) async {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(60)
    while !condition(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
}

@MainActor
@Test func anAccentChangeReachesControlsBehindThemedWithoutAnyOtherRefresh() async throws {
    let store = ThemeStore(preferencesStore: MemoryThemePreferencesStore(ThemePreferences(mode: .light)))
    let seen = Seen()
    let hosting = NSHostingView(rootView: SheetLike(store: store, seen: seen))
    hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
    hosting.layoutSubtreeIfNeeded()
    let before = try #require(seen.accent)
    #expect(before == store.resolved.accentFill)

    store.preferences.accentID = "iris"
    #expect(store.resolved.accentFill != before, "the store itself changed")
    await spin { seen.accent == store.resolved.accentFill }
    #expect(seen.accent == store.resolved.accentFill, "the controls' theme followed the accent")
}

@MainActor
@Test func lightDarkAndSystemChangesReachTheSameControls() async throws {
    let store = ThemeStore(preferencesStore: MemoryThemePreferencesStore(ThemePreferences(mode: .light)))
    let seen = Seen()
    let hosting = NSHostingView(rootView: SheetLike(store: store, seen: seen))
    hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
    hosting.layoutSubtreeIfNeeded()
    #expect(seen.scheme == .light)
    store.preferences.mode = .dark
    await spin { seen.scheme == .dark }
    #expect(seen.scheme == .dark && seen.accent == store.resolved.accentFill)
    store.preferences.mode = .system
    store.systemAppearance = .light
    await spin { seen.scheme == .light }
    #expect(seen.scheme == .light)
}

@MainActor
@Test func aThemeChangeNeverAnimatesEvenFromInsideWithAnimation() async throws {
    let store = ThemeStore(preferencesStore: MemoryThemePreferencesStore(ThemePreferences(mode: .light)))
    let seen = Seen()
    let hosting = NSHostingView(rootView: AnimationProbe(seen: seen).themed(by: store))
    hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
    hosting.layoutSubtreeIfNeeded()
    withAnimation(.linear(duration: 1)) { store.preferences.accentID = "iris" }
    let iris = store.resolved.accentFill
    await spin { seen.animated.contains { $0.accent == iris } }
    let updates = seen.animated.filter { $0.accent == iris }
    #expect(!updates.isEmpty && updates.allSatisfy { !$0.animates }, "the accent change was drawn without animation")
}

@MainActor
private func buttonFill(_ hosting: NSHostingView<some View>) -> (r: Double, g: Double, b: Double)? {
    hosting.layoutSubtreeIfNeeded()
    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    var best: (score: Double, rgb: (Double, Double, Double))?
    for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let hi = max(c.redComponent, c.greenComponent, c.blueComponent), lo = min(c.redComponent, c.greenComponent, c.blueComponent)
            let saturation = hi - lo
            if best == nil || saturation > best!.score { best = (saturation, (c.redComponent, c.greenComponent, c.blueComponent)) }
        }
    }
    return best.map { (r: $0.rgb.0, g: $0.rgb.1, b: $0.rgb.2) }
}

private func distance(_ a: (r: Double, g: Double, b: Double), _ b: ThemeColor) -> Double {
    let c = NSColor(b.color).usingColorSpace(.sRGB) ?? .black
    return abs(a.r - c.redComponent) + abs(a.g - c.greenComponent) + abs(a.b - c.blueComponent)
}

@MainActor
@Test func theProminentButtonsFillFollowsTheThemesAccentLive() async throws {
    let store = ThemeStore(preferencesStore: MemoryThemePreferencesStore(ThemePreferences(mode: .light, accentID: "pine")))
    let seen = Seen()
    let hosting = NSHostingView(rootView: SheetLike(store: store, seen: seen))
    hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
    hosting.layoutSubtreeIfNeeded()
    let pine = store.resolved.accentFill
    let first = try #require(buttonFill(hosting))
    #expect(distance(first, pine) < 0.35, "the button wears the theme's accent, not the system's")
    store.preferences.accentID = "iris"
    let iris = store.resolved.accentFill
    #expect(iris != pine)
    await spin { if let now = buttonFill(hosting) { distance(now, iris) < 0.35 } else { false } }
    let second = try #require(buttonFill(hosting))
    #expect(distance(second, iris) < 0.35 && distance(second, pine) > 0.2, "the same button restyled at once")
}
#endif
