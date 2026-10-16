extension ActionCatalog {
    static let searchRanking: [ActionDescriptor] = [
        ActionDescriptor(.resetSearchLearning, "Reset search learning", category: .app,
                         keywords: ["search", "ranking", "clicks", "forget", "most relevant", "learning", "privacy"],
                         appearsInMenu: false),
        ActionDescriptor(.toggleSearchSort, "Sort search results: most relevant or most recent", category: .app,
                         scopes: [.list, .reader],
                         keywords: ["search", "sort", "order", "most recent", "most relevant", "newest", "date", "relevance"],
                         appearsInMenu: false),
        ActionDescriptor(.copySearchRanking, "Copy why this search result ranks here", category: .app,
                         scopes: [.list, .reader], target: .focusedThread,
                         keywords: ["search", "ranking", "why", "score", "debug", "explain", "relevance"],
                         appearsInMenu: false),
    ]
}
