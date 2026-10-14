import Foundation
import MailActions
import MailModel
import MailRender
import OpenHumanCore

@MainActor
public final class SuperhumanCoreActionHandler: ActionHandler {
    static let ids: [ActionID] = [.printConversation, .zoomIn, .zoomOut, .zoomReset, .toggleContextSidebar,
                                  .addToSplit, .splitFromSearch, .saveMessageAsSnippet, .addEventsTab, .rescanEvents,
                                  .addNewslettersSplit]

    private(set) weak var environment: AppEnvironment?
    let feedback: ActionFeedback
    public weak var printer: (any ConversationPrinting)?
    public var zoom: ReaderPreferences = .shared
    static let maxSplitName = 40

    init(environment: AppEnvironment, feedback: ActionFeedback) {
        self.environment = environment
        self.feedback = feedback
    }

    public var contextSidebar: ContextSidebarModel? {
        if let contextStorage { return contextStorage }
        guard let environment else { return nil }
        let model = ContextSidebarModel(environment: environment)
        contextStorage = model
        return model
    }

    private var contextStorage: ContextSidebarModel?

    public func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        switch id {
        case .printConversation:
            return printer == nil ? .hidden : .enabled
        case .zoomIn:
            return zoom.canZoomIn ? .enabled : .disabled(.other("The text is at its largest size"))
        case .zoomOut:
            return zoom.canZoomOut ? .enabled : .disabled(.other("The text is at its smallest size"))
        case .zoomReset:
            return zoom.textZoom == 1 ? .disabled(.other("The text is at its actual size")) : .enabled
        case .addToSplit:
            guard let environment, context.account != nil, environment.actions.presenter?.canPresent(.palette) == true,
                  !environment.actions.palette.isOpen else { return .hidden }
            return .enabled
        case .splitFromSearch:
            guard case .search(let query)? = context.location,
                  !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .hidden }
            return .enabled
        case .addEventsTab:
            return eventsOffer(context) == nil ? .hidden : .enabled
        case .addNewslettersSplit:
            return newslettersTabName(context) == nil ? .hidden : .enabled
        case .rescanEvents:
            return context.account != nil && environment?.settings != nil ? .enabled : .hidden
        default:
            return .enabled
        }
    }

    public func perform(_ request: ActionRequest) -> ActionPerformance {
        let c = request.context
        switch request.id {
        case .printConversation:
            return printConversation(c)
        case .zoomIn:
            zoom.zoomIn()
            return .done
        case .zoomOut:
            zoom.zoomOut()
            return .done
        case .zoomReset:
            zoom.resetZoom()
            return .done
        case .toggleContextSidebar:
            guard let model = contextSidebar else { return .notHandled }
            model.toggle()
            return .done
        case .addToSplit:
            guard let environment, let presenter = environment.actions.presenter, presenter.canPresent(.palette) else {
                return .notHandled
            }
            let palette = environment.actions.palette
            palette.open(host: request.host, context: c)
            palette.query = AddToSplit.paletteQuery
            presenter.present(.palette)
            return .done
        case .splitFromSearch:
            guard case .search(let query)? = c.location, let account = c.account else { return .notHandled }
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .notHandled }
            let name = text.count > Self.maxSplitName ? String(text.prefix(Self.maxSplitName - 1)) + "…" : text
            return .started(Task { [weak self] in
                await self?.createSplit(named: name, ruleText: text, account: account, title: "New split “\(name)”")
            })
        case .addEventsTab:
            guard let account = c.account, let offer = eventsOffer(c) else { return .notHandled }
            return .started(Task { [weak self] in await self?.acceptEventsOffer(offer, account: account) })
        case .addNewslettersSplit:
            guard let account = c.account, let name = newslettersTabName(c) else { return .notHandled }
            return .started(Task { [weak self] in await self?.addNewslettersSplit(named: name, account: account) })
        case .rescanEvents:
            guard let account = c.account else { return .notHandled }
            return .started(Task { [weak self] in await self?.rescanEvents(account: account) })
        case .saveMessageAsSnippet:
            guard let message = c.focusedMessage else { return .notHandled }
            let reader = environment?.router.accounts.first { $0.id == message.account }?.reader
            let subject = reader?.thread == c.focusedThread ? reader?.subject ?? "" : ""
            return .started(Task { [weak self] in await self?.saveSnippet(from: message, subject: subject) })
        default:
            return .notHandled
        }
    }

    private func printConversation(_ c: ActionContext) -> ActionPerformance {
        guard let thread = c.focusedThread, let printer, let data = environment?.data else { return .notHandled }
        let feedback = self.feedback
        return .started(Task {
            guard let document = await ConversationPrint.document(for: thread, data: data) else {
                feedback.failed("Couldn't read the conversation to print it")
                return
            }
            printer.print(document)
        })
    }

    func saveSnippet(from message: MessageKey, subject: String) async {
        guard let environment, let commands = environment.commands else { return }
        guard environment.status.safeMode.allowsMailChanges else {
            feedback.refuse(.saveMessageAsSnippet, .safeMode)
            return
        }
        guard let content = await ConversationPrint.content(of: message, data: environment.data) else {
            feedback.failed("Couldn't read the message")
            return
        }
        let text = PlainTextExtractor.extract(content).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            environment.notices.post("This message has no text to save", style: .info, duration: NoticeCenter.infoDuration)
            return
        }
        let bare = AddToSplit.strippedSubject(subject)
        let name = bare.isEmpty ? String(text.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines) : bare
        let document = RichTextDocument(blocks: text.components(separatedBy: "\n").map {
            .paragraph($0.isEmpty ? [] : [.text($0, [])])
        })
        let variables = SnippetExpander.variableNames(in: text).map { SnippetVariableInfo(name: $0) }
        do {
            let saved = try await commands.upsertSnippet(SnippetInfo(account: message.account, name: name,
                                                                     bodyHTML: ComposeSerializer.html(document, signature: nil),
                                                                     variables: variables))
            environment.notices.post("Saved snippet “\(saved.name)”", style: .info, duration: NoticeCenter.infoDuration)
        } catch MailPortError.blockedBySafeMode {
            feedback.refuse(.saveMessageAsSnippet, .safeMode)
        } catch {
            feedback.failed((error as? MailPortError)?.description ?? "Couldn't save the snippet")
        }
    }
}

extension ActionRegistry {
    public var superhumanCore: SuperhumanCoreActionHandler? { core?.extras }
}
