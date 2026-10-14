import AppKit
import MailFeatures
import MailRender
import MailTheme

@MainActor
public protocol ReaderHost: AnyObject {
    var readerRouter: AppRouter? { get }
}

extension MainContentViewController: ReaderHost {
    public var readerRouter: AppRouter? { router }
}

public enum ReaderAppearance {
    public static func appearance(of tokens: ThemeTokens) -> ThemeAppearance {
        tokens.bgWindow.relativeLuminance < 0.2 ? .dark : .light
    }

    public static func renderer(for tokens: ThemeTokens) -> MessageRenderer {
        MessageRenderer(theme: tokens, appearance: appearance(of: tokens), emailColors: tokens.readerEmailColors)
    }
}
