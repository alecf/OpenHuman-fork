import Foundation
import MailModel

public enum SearchHeaderScope {
    public static func shows(searchOpen: Bool, location: MailLocation?, unifiedInboxShown: Bool, calendarShown: Bool) -> Bool {
        guard searchOpen, !unifiedInboxShown, !calendarShown, case .search? = location else { return false }
        return true
    }
}

extension AppRouter {
    public var showsSearchResultsHeader: Bool {
        SearchHeaderScope.shows(searchOpen: active?.searchOpen == true, location: active?.location,
                                unifiedInboxShown: unifiedInbox != nil,
                                calendarShown: environment.calendarWindowIfStarted?.isOpen == true)
    }
}
