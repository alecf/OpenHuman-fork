import AppKit
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI

public struct CalendarWindowView: View {
    @Bindable var model: CalendarWindowModel
    let router: AppRouter
    @Environment(\.theme) private var theme

    static let tickInterval: Duration = .seconds(15)

    public init(model: CalendarWindowModel, router: AppRouter) {
        self.model = model
        self.router = router
    }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                CalendarWindowToolbar(model: model, router: router)
                Rectangle().fill(theme.borderHairline.color).frame(height: theme.borderWidthHairline)
                Group {
                    if model.kind == .month {
                        CalendarMonthView(model: model)
                    } else {
                        CalendarTimeGridView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) { cardOverlay }
            }
            CalendarRightPanel(model: model, router: router)
        }
        .background(theme.bgWindow.color)
        .overlay { if let question = model.scopeQuestion { scopeQuestion(question) } }
        .overlay { if let question = model.removeQuestion { removeQuestion(question) } }
        .environment(\.timeZone, model.timeZone)
        .onAppear {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .task(id: model.isOpen) {
            guard model.isOpen else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard !Task.isCancelled else { return }
                await model.tick()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await model.windowDidBecomeKey() }
        }
        .onChange(of: modalComposerOpen) {
            if modalComposerOpen { Task { await model.close() } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Calendar")
        .accessibilityIdentifier("calendar.window")
    }

    private var modalComposerOpen: Bool {
        guard let session = router.environment.composeIfStarted?.windowSession else { return false }
        return session.isOpen && session.placement == .modal
    }

    @ViewBuilder
    private var cardOverlay: some View {
        if model.card != nil {
            GeometryReader { proxy in
                CalendarEventCardView(model: model, maxHeight: max(proxy.size.height - 2 * theme.space5, 220))
                    .frame(width: CGFloat(CalendarCardMode.width(available: Double(proxy.size.width - 2 * theme.space5))))
                    .padding(theme.space5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        } else if model.showsPendingCard {
            GeometryReader { proxy in
                ScrollView(.vertical) {
                    CalendarDraftEditor(model: model.sidebar, showsDay: false,
                                        onCancel: { Task { await model.cancelPending() } })
                }
                .frame(width: CGFloat(CalendarCardMode.width(available: Double(proxy.size.width - 2 * theme.space5))))
                .frame(maxHeight: max(proxy.size.height - 2 * theme.space5, 220))
                .fixedSize(horizontal: false, vertical: true)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusLG))
                .themeShadow(theme.component.popover.shadow)
                .padding(theme.space5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .accessibilityIdentifier("calendar.window.pendingCard")
            }
        }
    }

    private func removeQuestion(_ question: CalendarRemoveQuestion) -> some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()
                .onTapGesture { Task { await model.escape() } }
            VStack(alignment: .leading, spacing: theme.space4) {
                Text(question.text).themeFont(theme.typeBody).foregroundStyle(theme.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: theme.space3) {
                    Button("Delete", role: .destructive) { Task { await model.confirmRemove() } }
                        .buttonStyle(.borderedProminent).tint(theme.textDanger.color)
                        .accessibilityIdentifier("calendar.remove.confirm")
                    Spacer(minLength: 0)
                    Button("Cancel") { Task { await model.escape() } }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("calendar.remove.cancel")
                }
            }
            .padding(theme.space5)
            .frame(width: 460)
            .background(RoundedRectangle(cornerRadius: theme.radiusLG).fill(theme.bgElevated.color))
            .overlay(RoundedRectangle(cornerRadius: theme.radiusLG)
                .strokeBorder(theme.borderElevated.color, lineWidth: theme.borderWidthHairline))
            .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("calendar.removeQuestion")
        }
    }

    private func scopeQuestion(_ question: CalendarScopeQuestion) -> some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()
                .onTapGesture { Task { await model.escape() } }
            VStack(alignment: .leading, spacing: theme.space4) {
                Text(question.text).themeFont(theme.typeBody).foregroundStyle(theme.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: theme.space3) {
                    if question.action == .save, model.card?.form != nil {
                        ForEach(question.scopes, id: \.self) { scope in
                            Button(scope.title) { Task { await model.answerRecurrenceScope(scope) } }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("calendar.scope.\(scope.rawValue)")
                        }
                    } else {
                        Button("This event") { Task { await model.answerScope(.thisEvent) } }
                            .buttonStyle(.borderedProminent).tint(theme.accentFill.color)
                            .keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("calendar.scope.this")
                        Button("All events") { Task { await model.answerScope(.allEvents) } }
                            .accessibilityIdentifier("calendar.scope.all")
                    }
                    Spacer(minLength: 0)
                    Button("Cancel") { Task { await model.escape() } }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(theme.space5)
            .frame(width: 460)
            .background(RoundedRectangle(cornerRadius: theme.radiusLG).fill(theme.bgElevated.color))
            .overlay(RoundedRectangle(cornerRadius: theme.radiusLG)
                .strokeBorder(theme.borderElevated.color, lineWidth: theme.borderWidthHairline))
            .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("calendar.scopeQuestion")
        }
    }
}

struct CalendarWindowToolbar: View {
    @Bindable var model: CalendarWindowModel
    let router: AppRouter
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.space3) {
            Button { Task { await model.goToToday() } } label: {
                Text("Today").themeFont(theme.typeLabel).foregroundStyle(theme.textPrimary.color)
                    .padding(.horizontal, theme.space4)
                    .frame(height: 26)
                    .overlay(RoundedRectangle(cornerRadius: theme.radiusMD)
                        .strokeBorder(theme.borderControl.color, lineWidth: theme.borderWidthHairline))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Today  T")
            .accessibilityIdentifier("calendar.window.today")
            chevron("chevron.left", help: "Previous  −  K", label: "Previous") { await model.move(by: -1) }
            chevron("chevron.right", help: "Next  =  J", label: "Next") { await model.move(by: 1) }
            Text(model.title).themeFont(theme.typeTitle).foregroundStyle(theme.textPrimary.color)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("calendar.window.title")
            Spacer(minLength: theme.space3)
            if let progress = model.progress {
                Text(progress.text).themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                    .accessibilityIdentifier("calendar.window.updating")
            }
            Picker("View", selection: Binding(get: { model.kind }, set: { kind in Task { await model.setKind(kind) } })) {
                ForEach(CalendarViewKind.allCases, id: \.self) { kind in Text(kind.title).tag(kind) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Day  D · Week  W · Month  M")
            .accessibilityIdentifier("calendar.window.views")
            chevron("arrow.clockwise", help: "Refresh", label: "Refresh calendar") { await model.refresh() }
            chevron("xmark", help: "Back to Mail  1", label: "Back to Mail") {
                _ = router.perform(.calendarBackToMail, source: .toolbar)
            }
        }
        .padding(.horizontal, theme.space5)
        .frame(height: theme.component.toolbar.height)
    }

    private func chevron(_ symbol: String, help: String, label: String,
                         action: @escaping @MainActor () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Image(systemName: symbol).font(.system(size: 13, weight: .regular))
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.textSecondary.color)
        .help(help)
        .accessibilityLabel(label)
    }
}
