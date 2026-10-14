import Foundation
import Testing
@testable import OpenHumanGmail

@Suite struct WriteGuardRefusalTests {
    private let api = WG.api, upload = WG.upload

    @Test func everySendIsRefused() async {
        let meta = #"{"threadId":"t1"}"#
        let cases: [(String, HTTPRequest)] = [
            ("messages.send upload", WG.upload("POST", upload + "messages/send?uploadType=multipart", metadata: meta,
                                               message: WG.synthetic)),
            ("messages.send upload, no thread", WG.upload("POST", upload + "messages/send?uploadType=multipart",
                                                          metadata: "{}", message: WG.synthetic)),
            ("messages.send JSON", WG.json("POST", api + "messages/send", ["raw": "eA", "threadId": "t1"])),
            ("messages.send resumable", WG.request("POST", upload + "messages/send?uploadType=resumable")),
            ("drafts.send of an allowlisted draft", WG.json("POST", api + "drafts/send", ["id": "d1"])),
            ("drafts.send upload", WG.upload("POST", upload + "drafts/send?uploadType=multipart",
                                             metadata: #"{"id":"d1"}"#, message: WG.synthetic)),
            ("drafts.send of another draft", WG.json("POST", api + "drafts/send", ["id": "d9"])),
            ("send with a method override", WG.json("POST", api + "drafts/send", ["id": "d1"],
                                                    extraHeaders: ["X-HTTP-Method-Override": "POST"])),
        ]
        for (label, request) in cases { await expectWriteRefused(request, label) }
    }

    @Test func insertVariantsAreRefused() async {
        let q = upload + "messages?"
        let cases: [(String, HTTPRequest)] = [
            ("deleted=true", WG.insert(url: q + "uploadType=multipart&internalDateSource=receivedTime&deleted=true")),
            ("deleted=false", WG.insert(url: q + "uploadType=multipart&internalDateSource=receivedTime&deleted=false")),
            ("Deleted=TRUE", WG.insert(url: q + "uploadType=multipart&internalDateSource=receivedTime&Deleted=TRUE")),
            ("internalDateSource=dateHeader", WG.insert(url: q + "uploadType=multipart&internalDateSource=dateHeader")),
            ("no internalDateSource", WG.insert(url: q + "uploadType=multipart")),
            ("no query", WG.insert(url: upload + "messages")),
            ("uploadType=media", WG.insert(url: q + "uploadType=media&internalDateSource=receivedTime")),
            ("uploadType=resumable", WG.insert(url: q + "uploadType=resumable&internalDateSource=receivedTime")),
            ("repeated uploadType", WG.insert(url: q + "uploadType=multipart&uploadType=multipart&internalDateSource=receivedTime")),
            ("extra parameter", WG.insert(url: q + "uploadType=multipart&internalDateSource=receivedTime&neverMarkSpam=true")),
            ("processForCalendar", WG.insert(url: q + "uploadType=multipart&internalDateSource=receivedTime&processForCalendar=true")),
            ("fields", WG.insert(url: q + "uploadType=multipart&internalDateSource=receivedTime&fields=id")),
            ("insert without the media upload endpoint",
             WG.json("POST", api + "messages", ["raw": "eA", "labelIds": ["Label_T"]])),
            ("insert via the api path with upload query",
             WG.json("POST", api + "messages?uploadType=multipart&internalDateSource=receivedTime",
                     ["raw": "eA", "labelIds": ["Label_T"]])),
            ("messages.import upload", WG.insert(url: upload + "messages/import?uploadType=multipart")),
            ("messages.import JSON", WG.json("POST", api + "messages/import", ["raw": "eA", "labelIds": ["Label_T"]])),
            ("PUT insert", WG.upload("PUT", WG.insertURL, metadata: #"{"labelIds":["Label_T"]}"#, message: WG.synthetic)),
            ("no OpenHuman/Test label", WG.insert(labelIDs: ["INBOX", "UNREAD"])),
            ("no labels", WG.insert(labelIDs: [])),
            ("OpenHuman/Snoozed instead of Test", WG.insert(labelIDs: ["Label_S", "INBOX"])),
            ("a user label", WG.insert(labelIDs: ["Label_T", "Label_U"])),
            ("SENT", WG.insert(labelIDs: ["Label_T", "SENT"])),
            ("DRAFT", WG.insert(labelIDs: ["Label_T", "DRAFT"])),
            ("threadId in the metadata", WG.upload("POST", WG.insertURL,
                                                   metadata: #"{"labelIds":["Label_T"],"threadId":"t9"}"#,
                                                   message: WG.synthetic)),
            ("labelIds not strings", WG.upload("POST", WG.insertURL, metadata: #"{"labelIds":["Label_T",1]}"#,
                                               message: WG.synthetic)),
            ("labelIds a string", WG.upload("POST", WG.insertURL, metadata: #"{"labelIds":"Label_T"}"#,
                                            message: WG.synthetic)),
            ("metadata not JSON", WG.upload("POST", WG.insertURL, metadata: "labelIds=Label_T", message: WG.synthetic)),
            ("metadata a JSON array", WG.upload("POST", WG.insertURL, metadata: #"["Label_T"]"#, message: WG.synthetic)),
        ]
        for (label, request) in cases { await expectWriteRefused(request, label) }
        var unknown = WG.allowlist
        unknown.labels = [:]
        await expectWriteRefused(WG.insert(), "Test label id unknown", allowlist: unknown)
    }

    @Test func insertOfANonSyntheticMessageIsRefused() async {
        let cases: [(String, Data)] = [
            ("real From", WG.message(replacing: "From", with: "From: Alice Example <alice@example.com>")),
            ("bare real From", WG.message(replacing: "From", with: "From: alice@example.com")),
            ("no From", WG.message(replacing: "From", with: nil)),
            ("From list", WG.message(replacing: "From", with: "From: test@openhuman.invalid, alice@example.com")),
            ("From with trailing text", WG.message(replacing: "From", with: "From: <test@openhuman.invalid> x")),
            ("lookalike domain", WG.message(replacing: "From", with: "From: <test@openhuman.invalid.example.com>")),
            ("two From", WG.message(WG.syntheticHeaders + ["From: Alice <alice@example.com>"])),
            ("Sender", WG.message(WG.syntheticHeaders + ["Sender: alice@example.com"])),
            ("Reply-To", WG.message(WG.syntheticHeaders + ["Reply-To: alice@example.com"])),
            ("real subject", WG.message(replacing: "Subject", with: "Subject: Quarterly numbers")),
            ("Re: subject", WG.message(replacing: "Subject", with: "Subject: Re: [OpenHuman test] run1 1")),
            ("prefix without space", WG.message(replacing: "Subject", with: "Subject: [OpenHuman test]run1")),
            ("no subject", WG.message(replacing: "Subject", with: nil)),
            ("two subjects", WG.message(WG.syntheticHeaders + ["Subject: [OpenHuman test] run1 2"])),
            ("real Message-ID", WG.message(replacing: "Message-ID", with: "Message-ID: <CAF123@mail.gmail.com>")),
            ("no Message-ID", WG.message(replacing: "Message-ID", with: nil)),
            ("two ids in Message-ID", WG.message(replacing: "Message-ID",
                                                 with: "Message-ID: <a@openhuman.invalid> <b@openhuman.invalid>")),
            ("References a real message", WG.message(WG.syntheticHeaders + ["References: <CAF123@mail.gmail.com>"])),
            ("References mixing synthetic and real",
             WG.message(WG.syntheticHeaders + ["References: <a@openhuman.invalid> <CAF123@mail.gmail.com>"])),
            ("folded References with a real id",
             WG.message(WG.syntheticHeaders + ["References: <a@openhuman.invalid>", " <CAF123@mail.gmail.com>"])),
            ("In-Reply-To a real message", WG.message(WG.syntheticHeaders + ["In-Reply-To: <CAF123@mail.gmail.com>"])),
            ("In-Reply-To free text", WG.message(WG.syntheticHeaders + ["In-Reply-To: your message"])),
            ("two References", WG.message(WG.syntheticHeaders + ["References: <a@openhuman.invalid>",
                                                                  "References: <b@openhuman.invalid>"])),
            ("no header block", Data("just text".utf8)),
            ("leading continuation", WG.message([" folded"] + WG.syntheticHeaders)),
            ("garbage header line", WG.message(WG.syntheticHeaders + ["not a header"])),
        ]
        for (label, message) in cases { await expectWriteRefused(WG.insert(message: message), label) }
    }

    @Test func malformedUploadBodiesAreRefused() async {
        let meta = #"{"labelIds":["Label_T"]}"#
        let b = "oh_upload_0123456789abcdef"
        var inside = WG.synthetic
        inside.append(Data("\r\n--\(b)\r\nContent-Type: message/rfc822\r\n\r\nsmuggled".utf8))
        var bare = WG.synthetic
        bare.append(Data("x--\(b)".utf8))
        let cases: [(String, HTTPRequest)] = [
            ("three parts", WG.upload("POST", WG.insertURL, metadata: meta, message: WG.synthetic,
                                      extraPart: "Content-Type: message/rfc822\r\n\r\n" + "x")),
            ("preamble", WG.upload("POST", WG.insertURL, metadata: meta, message: WG.synthetic, preamble: "hello\r\n")),
            ("epilogue", WG.upload("POST", WG.insertURL, metadata: meta, message: WG.synthetic, epilogue: "\r\nmore")),
            ("no close delimiter", WG.request("POST", WG.insertURL, body: Data("--\(b)\r\nContent-Type: application/json\r\n\r\n\(meta)".utf8),
                                              extraHeaders: ["Content-Type": "multipart/related; boundary=\(b)"])),
            ("boundary inside the message", WG.upload("POST", WG.insertURL, metadata: meta, message: inside)),
            ("bare boundary inside the message", WG.upload("POST", WG.insertURL, metadata: meta, message: bare)),
            ("LF line ends", WG.upload("POST", WG.insertURL, metadata: meta, message: WG.synthetic, newline: "\n")),
            ("base64 metadata", WG.upload("POST", WG.insertURL, metadata: "eyJsYWJlbElkcyI6WyJMYWJlbF9UIl19",
                                          message: WG.synthetic,
                                          metaHeaders: "Content-Type: application/json\r\nContent-Transfer-Encoding: base64")),
            ("base64 message", WG.upload("POST", WG.insertURL, metadata: meta, message: WG.synthetic,
                                         messageHeaders: "Content-Type: message/rfc822\r\nContent-Transfer-Encoding: base64")),
            ("parts swapped", WG.upload("POST", WG.insertURL, metadata: meta, message: WG.synthetic,
                                        metaHeaders: "Content-Type: message/rfc822",
                                        messageHeaders: "Content-Type: application/json")),
            ("metadata without Content-Type", WG.upload("POST", WG.insertURL, metadata: meta, message: WG.synthetic,
                                                        metaHeaders: "Content-ID: <1>")),
            ("extra part header", WG.upload("POST", WG.insertURL, metadata: meta, message: WG.synthetic,
                                            metaHeaders: "Content-Type: application/json\r\nX-Goog-Thing: 1")),
            ("folded part header", WG.upload("POST", WG.insertURL, metadata: meta, message: WG.synthetic,
                                             metaHeaders: "Content-Type:\r\n application/json")),
            ("multipart/mixed", WG.upload("POST", WG.insertURL, metadata: meta, message: WG.synthetic,
                                          contentType: "multipart/mixed; boundary=\(b)")),
            ("no boundary", WG.upload("POST", WG.insertURL, metadata: meta, message: WG.synthetic,
                                      contentType: "multipart/related")),
            ("wrong boundary", WG.upload("POST", WG.insertURL, metadata: meta, message: WG.synthetic,
                                         contentType: "multipart/related; boundary=other")),
            ("JSON content type", WG.upload("POST", WG.insertURL, metadata: meta, message: WG.synthetic,
                                            contentType: "application/json")),
            ("empty body", WG.request("POST", WG.insertURL, extraHeaders: ["Content-Type": "multipart/related; boundary=x"])),
        ]
        for (label, request) in cases { await expectWriteRefused(request, label) }
    }

    @Test func labelChangesOutsideTheAllowlistAreRefused() async {
        let cases: [(String, HTTPRequest)] = [
            ("batchModify mixing allowed and disallowed ids",
             WG.json("POST", api + "messages/batchModify", ["ids": ["m1", "m9", "m2"], "removeLabelIds": ["INBOX"]])),
            ("batchModify one disallowed id last",
             WG.json("POST", api + "messages/batchModify", ["ids": ["m1", "m2", "m9"], "addLabelIds": ["STARRED"]])),
            ("batchModify only disallowed ids",
             WG.json("POST", api + "messages/batchModify", ["ids": ["m9"], "removeLabelIds": ["INBOX"]])),
            ("batchModify a thread id as a message id",
             WG.json("POST", api + "messages/batchModify", ["ids": ["t1"], "removeLabelIds": ["INBOX"]])),
            ("batchModify no ids", WG.json("POST", api + "messages/batchModify", ["ids": [], "removeLabelIds": ["INBOX"]])),
            ("batchModify ids missing", WG.json("POST", api + "messages/batchModify", ["removeLabelIds": ["INBOX"]])),
            ("batchModify ids not strings", WG.json("POST", api + "messages/batchModify", ["ids": [1], "addLabelIds": []])),
            ("batchModify too many ids",
             WG.json("POST", api + "messages/batchModify",
                     ["ids": Array(repeating: "m1", count: 1001), "removeLabelIds": ["INBOX"]])),
            ("batchModify adds a user label",
             WG.json("POST", api + "messages/batchModify", ["ids": ["m1"], "addLabelIds": ["Label_U"]])),
            ("batchModify removes a user label",
             WG.json("POST", api + "messages/batchModify", ["ids": ["m1"], "removeLabelIds": ["Label_U"]])),
            ("batchModify adds SENT", WG.json("POST", api + "messages/batchModify", ["ids": ["m1"], "addLabelIds": ["SENT"]])),
            ("batchModify adds DRAFT", WG.json("POST", api + "messages/batchModify", ["ids": ["m1"], "addLabelIds": ["DRAFT"]])),
            ("batchModify lower-case system label",
             WG.json("POST", api + "messages/batchModify", ["ids": ["m1"], "addLabelIds": ["inbox"]])),
            ("batchModify label ids not a list",
             WG.json("POST", api + "messages/batchModify", ["ids": ["m1"], "addLabelIds": "STARRED"])),
            ("batchModify extra field",
             WG.json("POST", api + "messages/batchModify", ["ids": ["m1"], "addLabelIds": ["STARRED"], "deleted": true])),
            ("batchModify text/plain", WG.json("POST", api + "messages/batchModify", ["ids": ["m1"]],
                                               contentType: "text/plain")),
            ("batchModify form encoded", WG.request("POST", api + "messages/batchModify", body: Data("ids=m1".utf8),
                                                    extraHeaders: ["Content-Type": "application/x-www-form-urlencoded"])),
            ("batchModify not JSON", WG.jsonText("POST", api + "messages/batchModify", "{ids: [m1]}")),
            ("batchModify with a query", WG.json("POST", api + "messages/batchModify?alt=json",
                                                 ["ids": ["m1"], "addLabelIds": ["STARRED"]])),
            ("modify a non-test message", WG.json("POST", api + "messages/m9/modify", ["removeLabelIds": ["INBOX"]])),
            ("modify adds a user label", WG.json("POST", api + "messages/m1/modify", ["addLabelIds": ["Label_U"]])),
            ("modify extra field", WG.json("POST", api + "messages/m1/modify", ["addLabelIds": ["STARRED"], "id": "m9"])),
            ("modify with a query", WG.json("POST", api + "messages/m1/modify?fields=id", ["addLabelIds": ["STARRED"]])),
            ("modify empty body", WG.request("POST", api + "messages/m1/modify", extraHeaders: ["Content-Type": "application/json"])),
            ("threads.modify of a test thread", WG.json("POST", api + "threads/t1/modify", ["removeLabelIds": ["INBOX"]])),
            ("threads.modify of another thread", WG.json("POST", api + "threads/t9/modify", ["removeLabelIds": ["INBOX"]])),
            ("trash of a non-test thread", WG.request("POST", api + "threads/t9/trash")),
            ("untrash of a non-test thread", WG.request("POST", api + "threads/t9/untrash")),
            ("trash of a message id as a thread", WG.request("POST", api + "threads/m1/trash")),
            ("trash of a non-test message", WG.request("POST", api + "messages/m9/trash")),
            ("untrash of a non-test message", WG.request("POST", api + "messages/m9/untrash")),
            ("trash of a thread id as a message", WG.request("POST", api + "messages/t1/trash")),
            ("trash with a body", WG.json("POST", api + "threads/t1/trash", ["id": "t9"])),
            ("trash with a query", WG.request("POST", api + "threads/t1/trash?alt=json")),
            ("PUT trash", WG.request("PUT", api + "threads/t1/trash")),
            ("GET-like trash with a lower-case method", WG.request("post", api + "threads/t1/trash")),
        ]
        for (label, request) in cases { await expectWriteRefused(request, label) }
    }

    @Test func draftWritesOutsideTheAllowlistAreRefused() async {
        let draftsURL = upload + "drafts?uploadType=multipart"
        let cases: [(String, HTTPRequest)] = [
            ("create in a non-test thread", WG.upload("POST", draftsURL, metadata: #"{"message":{"threadId":"t9"}}"#,
                                                      message: WG.synthetic)),
            ("create with extra message field", WG.upload("POST", draftsURL,
                                                          metadata: #"{"message":{"threadId":"t1","labelIds":["SENT"]}}"#,
                                                          message: WG.synthetic)),
            ("create with extra top-level field", WG.upload("POST", draftsURL, metadata: #"{"message":{},"send":true}"#,
                                                            message: WG.synthetic)),
            ("create with threadId not a string", WG.upload("POST", draftsURL, metadata: #"{"message":{"threadId":5}}"#,
                                                            message: WG.synthetic)),
            ("create with message not an object", WG.upload("POST", draftsURL, metadata: #"{"message":"t1"}"#,
                                                            message: WG.synthetic)),
            ("create with resumable upload", WG.upload("POST", upload + "drafts?uploadType=resumable",
                                                       metadata: #"{"message":{}}"#, message: WG.synthetic)),
            ("create with an extra parameter", WG.upload("POST", draftsURL + "&deleted=true", metadata: #"{"message":{}}"#,
                                                         message: WG.synthetic)),
            ("create without the upload endpoint", WG.json("POST", api + "drafts", ["message": ["raw": "eA"]])),
            ("update of another draft", WG.upload("PUT", upload + "drafts/d9?uploadType=multipart",
                                                  metadata: #"{"id":"d9","message":{}}"#, message: WG.synthetic)),
            ("update whose metadata names another draft", WG.upload("PUT", upload + "drafts/d1?uploadType=multipart",
                                                                    metadata: #"{"id":"d9","message":{}}"#,
                                                                    message: WG.synthetic)),
            ("update into a non-test thread", WG.upload("PUT", upload + "drafts/d1?uploadType=multipart",
                                                        metadata: #"{"id":"d1","message":{"threadId":"t9"}}"#,
                                                        message: WG.synthetic)),
            ("update without the upload endpoint", WG.json("PUT", api + "drafts/d1", ["id": "d1", "message": ["raw": "eA"]])),
            ("POST update", WG.upload("POST", upload + "drafts/d1?uploadType=multipart",
                                      metadata: #"{"id":"d1","message":{}}"#, message: WG.synthetic)),
            ("delete of another draft", WG.request("DELETE", api + "drafts/d9")),
            ("delete with a body", WG.json("DELETE", api + "drafts/d1", ["id": "d9"])),
            ("delete with a query", WG.request("DELETE", api + "drafts/d1?alt=json")),
            ("delete via upload path", WG.request("DELETE", upload + "drafts/d1")),
        ]
        for (label, request) in cases { await expectWriteRefused(request, label) }
    }

    @Test func labelWritesOutsideOpenHumanAreRefused() async {
        let cases: [(String, HTTPRequest)] = [
            ("create a user label", WG.json("POST", api + "labels", ["name": "Work"])),
            ("create the bare root", WG.json("POST", api + "labels", ["name": "OpenHuman"])),
            ("create the empty child", WG.json("POST", api + "labels", ["name": "OpenHuman/"])),
            ("create with the wrong case", WG.json("POST", api + "labels", ["name": "openhuman/Test"])),
            ("create with a leading space", WG.json("POST", api + "labels", ["name": " OpenHuman/Test"])),
            ("create nested elsewhere", WG.json("POST", api + "labels", ["name": "Work/OpenHuman/Test"])),
            ("create with a control character", WG.json("POST", api + "labels", ["name": "OpenHuman/a\u{0}b"])),
            ("create a too long name", WG.json("POST", api + "labels",
                                               ["name": "OpenHuman/" + String(repeating: "x", count: 300)])),
            ("create with a color", WG.json("POST", api + "labels",
                                            ["name": "OpenHuman/Test", "color": ["textColor": "#000000"]])),
            ("create with an unknown visibility", WG.json("POST", api + "labels",
                                                          ["name": "OpenHuman/Test", "labelListVisibility": "everywhere"])),
            ("create with name not a string", WG.json("POST", api + "labels", ["name": 1])),
            ("create without a name", WG.json("POST", api + "labels", ["labelListVisibility": "labelShow"])),
            ("update an OpenHuman label", WG.json("PUT", api + "labels/Label_T", ["name": "Work"])),
            ("patch an OpenHuman label", WG.json("PATCH", api + "labels/Label_T", ["name": "OpenHuman/Other"])),
            ("delete an OpenHuman label", WG.request("DELETE", api + "labels/Label_T")),
            ("delete a user label", WG.request("DELETE", api + "labels/Label_U")),
            ("delete a system label", WG.request("DELETE", api + "labels/INBOX")),
        ]
        for (label, request) in cases { await expectWriteRefused(request, label) }
    }

    @Test func forbiddenFamiliesAreRefusedEvenForTheRunsOwnResources() async {
        let cases: [(String, HTTPRequest)] = [
            ("permanent delete of a test message", WG.request("DELETE", api + "messages/m1")),
            ("permanent delete of a test thread", WG.request("DELETE", api + "threads/t1")),
            ("permanent delete of another thread", WG.request("DELETE", api + "threads/t9")),
            ("batchDelete of test messages", WG.json("POST", api + "messages/batchDelete", ["ids": ["m1"]])),
            ("create a filter", WG.json("POST", api + "settings/filters", ["criteria": ["from": "x"], "action": [:]])),
            ("delete a filter", WG.request("DELETE", api + "settings/filters/f1")),
            ("add a forwarding address", WG.json("POST", api + "settings/forwardingAddresses", ["forwardingEmail": "x"])),
            ("auto-forwarding", WG.json("PUT", api + "settings/autoForwarding", ["enabled": true])),
            ("vacation responder", WG.json("PUT", api + "settings/vacation", ["enableAutoReply": true])),
            ("signature", WG.json("PATCH", api + "settings/sendAs/me%40example.com", ["signature": "x"])),
            ("send-as create", WG.json("POST", api + "settings/sendAs", ["sendAsEmail": "x"])),
            ("delegates", WG.json("POST", api + "settings/delegates", ["delegateEmail": "x"])),
            ("imap", WG.json("PUT", api + "settings/imap", ["enabled": false])),
            ("pop", WG.json("PUT", api + "settings/pop", ["accessWindow": "disabled"])),
            ("language", WG.json("PUT", api + "settings/language", ["displayLanguage": "fr"])),
            ("S/MIME", WG.json("POST", api + "settings/sendAs/me/smimeInfo", ["pem": "x"])),
            ("CSE identities", WG.json("POST", api + "settings/cse/identities", [:])),
            ("watch", WG.json("POST", api + "watch", ["topicName": "x"])),
            ("stop", WG.request("POST", api + "stop")),
            ("another user's mailbox", WG.request("POST", "https://gmail.googleapis.com/gmail/v1/users/other%40example.com/threads/t1/trash")),
            ("another user's mailbox by id", WG.request("POST", "https://gmail.googleapis.com/gmail/v1/users/12345/threads/t1/trash")),
            ("the www host", WG.request("POST", "https://www.googleapis.com/gmail/v1/users/me/threads/t1/trash")),
            ("plain http", WG.request("POST", "http://gmail.googleapis.com/gmail/v1/users/me/threads/t1/trash")),
            ("another port", WG.request("POST", "https://gmail.googleapis.com:8443/gmail/v1/users/me/threads/t1/trash")),
            ("credentials in the URL", WG.request("POST", "https://u:p@gmail.googleapis.com/gmail/v1/users/me/threads/t1/trash")),
            ("a fragment", WG.request("POST", api + "threads/t1/trash#x")),
            ("v2 API", WG.request("POST", "https://gmail.googleapis.com/gmail/v2/users/me/threads/t1/trash")),
            ("percent-encoded segment", WG.request("POST", api + "threads/t1%2F..%2Ft9/trash")),
            ("dot segment", WG.request("POST", api + "threads/t1/../t9/trash")),
            ("empty segment", WG.request("POST", api + "threads//t1/trash")),
            ("trailing slash", WG.request("POST", api + "threads/t1/trash/")),
            ("matrix parameter", WG.request("POST", api + "threads/t1;x=1/trash")),
            ("unknown write", WG.json("POST", api + "messages/m1/archive", [:])),
            ("batch with a write inside", WG.request("POST", "https://gmail.googleapis.com/batch/gmail/v1",
                body: Data("--b\r\nContent-Type: application/http\r\n\r\nPOST /gmail/v1/users/me/threads/t1/trash HTTP/1.1\r\n\r\n--b--\r\n".utf8),
                extraHeaders: ["Content-Type": "multipart/mixed; boundary=b"])),
        ]
        for (label, request) in cases { await expectWriteRefused(request, label) }
    }

    @Test func methodTricksAreRefused() async {
        let trash = api + "threads/t1/trash"
        let cases: [(String, HTTPRequest)] = [
            ("override header on an allowed write", WG.request("POST", trash, extraHeaders: ["X-HTTP-Method-Override": "DELETE"])),
            ("override header, other spelling", WG.request("POST", trash, extraHeaders: ["x-http-method": "DELETE"])),
            ("override header on a GET", WG.request("GET", api + "threads/t1", extraHeaders: ["X-Method-Override": "DELETE"])),
            ("override query on an allowed write", WG.request("POST", trash + "?$httpMethod=DELETE")),
            ("override query on a GET", WG.request("GET", api + "threads/t1?_method=DELETE")),
            ("GET with a body", WG.request("GET", api + "threads/t1", body: Data("{}".utf8))),
            ("duplicate header names", WG.json("POST", api + "messages/m1/modify", ["addLabelIds": ["STARRED"]],
                                               extraHeaders: ["content-type": "text/plain"])),
            ("HEAD", WG.request("HEAD", api + "threads/t1")),
            ("OPTIONS", WG.request("OPTIONS", api + "threads/t1")),
            ("CONNECT", WG.request("CONNECT", "https://gmail.googleapis.com:443/")),
            ("TRACE", WG.request("TRACE", api + "threads/t1")),
            ("lower-case get", WG.request("get", api + "threads/t1")),
            ("PATCH a message", WG.json("PATCH", api + "messages/m1", ["labelIds": []])),
        ]
        for (label, request) in cases { await expectWriteRefused(request, label) }
        await expectWriteRefused(WG.request("", api + "threads/t1"), "empty method")
    }

    @Test func refusalReasonsNameTheRule() {
        let cases: [(HTTPRequest, String)] = [
            (WG.insert(url: upload + "messages?uploadType=multipart&internalDateSource=receivedTime&deleted=true"),
             "deleted parameter is never allowed"),
            (WG.json("POST", api + "drafts/send", ["id": "d1"]), "sending is never allowed"),
            (WG.upload("POST", upload + "messages/send?uploadType=multipart", metadata: "{}", message: WG.synthetic),
             "sending is never allowed"),
            (WG.json("POST", api + "messages/batchModify", ["ids": ["m1", "m9", "m2"], "removeLabelIds": ["INBOX"]]),
             "1 of 3 ids are not on the allowlist (first m9)"),
            (WG.request("POST", api + "threads/t9/trash"), "thread t9 is not on the allowlist"),
            (WG.json("POST", api + "labels", ["name": "Work"]), "outside OpenHuman/"),
            (WG.request("DELETE", api + "messages/m1"), "permanent delete is never allowed"),
            (WG.json("POST", api + "settings/filters", ["criteria": [:]]), "never written"),
            (WG.insert(labelIDs: ["INBOX"]), "without the OpenHuman/Test label id"),
            (WG.insert(message: WG.message(replacing: "From", with: "From: alice@example.com")), "not the synthetic sender"),
            (WG.json("POST", api + "messages", ["raw": "eA"]), "outside the media upload endpoint"),
            (WG.insert(url: upload + "messages/import?uploadType=multipart"), "messages.import"),
        ]
        for (request, expected) in cases {
            guard case .refuse(let reason) = WriteRules.evaluate(request, allowlist: WG.allowlist) else {
                Issue.record("expected a refusal containing \(expected)")
                continue
            }
            #expect(reason.contains(expected), "\(reason)")
            #expect(!reason.contains("Refusal("), "\(reason)")
        }
    }

    @Test func refusalReasonsCarryNoContent() {
        let secrets = ["Quarterly numbers", "alice@example.com", "Alice Example", "Work Secret", "TopSecretBody",
                       "CAF123", "zzz body"]
        let requests: [HTTPRequest] = [
            WG.insert(message: WG.message(replacing: "From", with: "From: Alice Example <alice@example.com>")),
            WG.insert(message: WG.message(replacing: "Subject", with: "Subject: Quarterly numbers")),
            WG.insert(message: WG.message(WG.syntheticHeaders + ["References: <CAF123@mail.gmail.com>"])),
            WG.insert(labelIDs: ["Label_T", "Work Secret"]),
            WG.json("POST", api + "labels", ["name": "Work Secret"]),
            WG.json("POST", api + "messages/batchModify", ["ids": ["m1", "alice@example.com"], "addLabelIds": ["STARRED"]]),
            WG.json("POST", api + "messages/batchModify", ["ids": ["m1"], "addLabelIds": ["Work Secret"]]),
            WG.json("POST", api + "messages/batchModify", ["ids": ["m1"], "Work Secret": ["STARRED"]]),
            WG.json("POST", api + "messages/send", ["raw": "TopSecretBody"]),
            WG.upload("POST", upload + "drafts?uploadType=multipart", metadata: #"{"message":{"threadId":"zzz body"}}"#,
                      message: WG.synthetic),
            WG.upload("POST", WG.insertURL, metadata: #"{"labelIds":["Label_T"]}"#, message: WG.synthetic,
                      metaHeaders: "Content-Type: application/json\r\nAlice Example: 1"),
        ]
        for request in requests {
            guard case .refuse(let reason) = WriteRules.evaluate(request, allowlist: WG.allowlist) else {
                Issue.record("expected a refusal")
                continue
            }
            for secret in secrets { #expect(!reason.contains(secret), "\(reason)") }
        }
        #expect(ReadOnlyTransport.redactingAddresses("PATCH /gmail/v1/users/me/settings/sendAs/me%40example.com")
                .contains("example.com") == false)
    }
}
