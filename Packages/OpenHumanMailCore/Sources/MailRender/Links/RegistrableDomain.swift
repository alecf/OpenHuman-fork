// Why: unlisted suffixes count as one label, so the check can miss a mismatch there but never invent one
import Foundation

public enum RegistrableDomain {
    public static func of(_ host: String) -> String? {
        var h = host.lowercased()
        if h.hasPrefix("["), h.hasSuffix("]") { return h }
        while h.hasSuffix(".") { h.removeLast() }
        guard !h.isEmpty, !h.hasPrefix("."), !h.contains("..") else { return nil }
        if isIPv4(h) { return h }
        let labels = h.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return h }
        for count in stride(from: min(4, labels.count - 1), through: 2, by: -1) {
            let suffix = labels.suffix(count).joined(separator: ".")
            if publicSuffixes.contains(suffix) { return labels.suffix(count + 1).joined(separator: ".") }
        }
        return labels.suffix(2).joined(separator: ".")
    }

    public static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in !p.isEmpty && p.count <= 3 && p.allSatisfy(\.isNumber) }
    }

    static let publicSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "ltd.uk", "plc.uk", "me.uk", "net.uk", "sch.uk", "nhs.uk", "police.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "asn.au", "id.au",
        "co.nz", "org.nz", "net.nz", "govt.nz", "ac.nz", "geek.nz", "school.nz",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "gr.jp", "lg.jp", "ed.jp", "ad.jp",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn",
        "com.hk", "org.hk", "net.hk", "edu.hk", "gov.hk", "idv.hk",
        "com.tw", "org.tw", "net.tw", "edu.tw", "gov.tw", "idv.tw",
        "co.kr", "or.kr", "ne.kr", "ac.kr", "go.kr", "re.kr",
        "co.in", "net.in", "org.in", "firm.in", "gen.in", "ind.in", "ac.in", "edu.in", "gov.in", "res.in",
        "com.sg", "org.sg", "net.sg", "edu.sg", "gov.sg",
        "com.my", "org.my", "net.my", "edu.my", "gov.my",
        "co.id", "or.id", "web.id", "ac.id", "go.id",
        "com.ph", "org.ph", "net.ph", "com.vn", "com.pk", "co.th", "in.th", "ac.th", "go.th", "or.th",
        "com.bd", "com.np", "com.lk",
        "co.il", "org.il", "net.il", "ac.il", "gov.il", "muni.il",
        "com.tr", "org.tr", "gen.tr", "net.tr", "edu.tr", "gov.tr",
        "com.sa", "com.eg", "com.qa", "com.kw", "com.bh", "com.om", "com.lb", "com.jo",
        "co.ae", "net.ae", "org.ae", "gov.ae", "ac.ae",
        "co.za", "org.za", "gov.za", "ac.za", "net.za", "web.za", "com.ng", "co.ke", "or.ke", "com.gh",
        "com.br", "net.br", "org.br", "gov.br", "edu.br", "com.mx", "org.mx", "gob.mx", "edu.mx", "net.mx",
        "com.ar", "com.co", "com.pe", "com.ve", "com.uy", "com.ec", "com.gt", "com.do", "com.py", "com.bo",
        "com.sv", "com.hn", "com.ni", "com.pa", "com.cu", "co.cr", "qc.ca", "on.ca", "bc.ca",
        "co.at", "or.at", "ac.at", "gv.at", "com.es", "org.es", "nom.es", "edu.es", "gob.es", "com.pt", "org.pt",
        "com.gr", "edu.gr", "gov.gr", "org.gr", "net.gr", "com.pl", "net.pl", "org.pl", "com.ua", "org.ua",
        "com.ro", "co.hu", "org.hu", "com.cy", "com.mt", "co.it",
        "github.io", "gitlab.io", "herokuapp.com", "appspot.com", "blogspot.com", "netlify.app", "vercel.app",
        "pages.dev", "workers.dev", "azurewebsites.net", "cloudfront.net", "s3.amazonaws.com", "web.app",
        "firebaseapp.com", "glitch.me", "repl.co", "wordpress.com", "wixsite.com", "myshopify.com",
        "sharepoint.com", "ngrok.io", "ngrok-free.app", "fly.dev", "onrender.com", "translate.goog",
        "r.appspot.com", "blogspot.co.uk", "weebly.com", "webflow.io", "carrd.co", "000webhostapp.com",
        "godaddysites.com", "square.site", "framer.website", "notion.site", "duckdns.org", "no-ip.org",
        "ddns.net", "dyndns.org", "azureedge.net", "windows.net", "blob.core.windows.net", "web.core.windows.net",
        "storage.googleapis.com", "firebasestorage.app", "surge.sh", "neocities.org", "readthedocs.io",
    ]
}
