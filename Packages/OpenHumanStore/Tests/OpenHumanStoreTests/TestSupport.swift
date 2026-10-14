import Testing
@testable import OpenHumanStore

func firstTid(_ r: UpsertResult) throws -> ThreadRowID {
    try #require(r.touchedThreads.first)
}

func detailOf(_ store: MailStore, _ r: UpsertResult) throws -> ThreadDetail {
    try detailOf(store, try firstTid(r))
}

func detailOf(_ store: MailStore, _ tid: ThreadRowID) throws -> ThreadDetail {
    try #require(try store.threadDetail(tid))
}
