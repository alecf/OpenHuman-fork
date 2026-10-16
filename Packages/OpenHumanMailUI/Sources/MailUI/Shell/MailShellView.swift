#if os(macOS)
import MailFeatures
import MailModel
import AppKit
import MailTheme
import SwiftUI

public struct MailShellView<Content: View>: View {
    let router: AppRouter
    let content: Content
    @State private var hints: HintBarModel
    @Environment(\.theme) private var theme
    @Environment(\.titleBarInset) private var titleBarInset

    public init(router: AppRouter, @ViewBuilder content: () -> Content) {
        self.router = router
        self.content = content()
        _hints = State(initialValue: HintBarModel(router: router))
    }

    public var body: some View {
        let environment = router.environment
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if titleBarInset > 0 {
                    TitleBarDragStrip().frame(height: titleBarInset)
                }
                ShellToolbar(router: router)
                if let banner = router.banner() {
                    BannerView(banner: banner, action: bannerAction(banner))
                }
            }
            .transaction { $0.disablesAnimations = true }
            HStack(spacing: 0) {
                if router.isLabelSidebarVisible {
                    LabelSidebarView(router: router)
                        .transaction { $0.disablesAnimations = true }
                }
                VStack(spacing: 0) {
                    if router.showsSearchResultsHeader, let summary = environment.overlays.search.resultsSummary {
                        HStack(spacing: 0) {
                            SearchResultsHeader(text: summary, search: environment.overlays.search)
                            if let query = environment.overlays.search.shownQuery,
                               router.list?.searchStatus?.canSortByRelevance == true {
                                SearchSortSwitch(query: query, model: environment.searchRanking)
                                    .padding(.trailing, theme.space5)
                            }
                        }
                    }
                    if router.showsSearchResultsHeader, let notice = environment.overlays.search.coverageNotice {
                        SearchCoverageRow(notice: notice, search: environment.overlays.search)
                    }
                    if let cleanup = environment.archiveSuggestion, let suggestion = cleanup.suggestion,
                       router.active?.id == suggestion.account, router.mode == .list {
                        ArchiveSuggestionBanner(model: cleanup, suggestion: suggestion)
                    } else if router.mode == .list, let account = router.active?.id,
                              let learned = environment.learning.bannerSuggestion(account: account) {
                        LearnedSuggestionBanner(center: environment.learning, suggestion: learned)
                    }
                    ZStack {
                        content
                        if let unified = router.unifiedInbox {
                            UnifiedInboxView(model: unified) { router.leaveAllInboxes() }
                                .id(ObjectIdentifier(unified))
                        }
                    }
                }
                    .transaction { $0.disablesAnimations = true }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        VStack(spacing: theme.space3) {
                            if let hint = CheckBeforeHint.shows(router: router) { hint }
                            ToastHostView(notices: environment.notices)
                        }
                        .padding(.bottom, theme.component.toast.bottom)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if let hint = router.sequenceHint {
                            SequenceHintView(text: hint)
                                .padding(theme.space5)
                        }
                    }
            }
            if FooterView.isVisible(status: environment.status, hints: hints) {
                FooterView(status: environment.status, hints: hints, theme: theme.tokens)
                    .transaction { $0.disablesAnimations = true }
            }
        }
        .background(theme.bgWindow.color)
        .overlayPreferenceValue(SearchDropdownKey.self, alignment: .topLeading) { request in
            if let request { SearchDropdownLayer(request: request) }
        }
        .shortcutTipRoot()
        .environment(\.actionDescriptors, environment.actions.descriptors)
        .task { hints.start() }
        .overlay { OverlayHostView(center: environment.overlays) }
    }

    private func bannerAction(_ banner: StatusBanner) -> (() -> Void)? {
        guard banner.kind == .auth, let account = banner.account, let accounts = router.environment.accounts else { return nil }
        return {
            Task {
                do { try await accounts.reauthorize(account) } catch {
                    router.environment.notices.post("Couldn't start sign-in", style: .error)
                }
            }
        }
    }
}

struct SequenceHintView: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(theme.typeKeycap.swiftUIFont)
            .foregroundStyle(theme.component.keycap.text.color)
            .padding(.horizontal, theme.space3)
            .frame(minHeight: theme.component.keycap.height)
            .background(RoundedRectangle(cornerRadius: theme.component.keycap.radius).fill(theme.component.keycap.bg.color))
            .overlay(RoundedRectangle(cornerRadius: theme.component.keycap.radius)
                .strokeBorder(theme.component.keycap.border.color, lineWidth: theme.borderWidthHairline))
            .accessibilityLabel("Waiting for the second key of \(text.dropLast())")
    }
}


struct TitleBarDragStrip: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard event.clickCount == 2, let window else { return super.mouseDown(with: event) }
            WindowZoomController.handleTitleBarDoubleClick(in: window)
        }
    }
}
#endif
