import Testing
@testable import MailRender

@Test func tokenizerDecodesEscapesBeforeURLDetection() {
    #expect(CSSTokenizer.tokenize("u\\72l(https://e.example/a.png)") == [.url("https://e.example/a.png")])
    #expect(CSSTokenizer.tokenize("URL( 'x' )") == [.function("URL"), .whitespace, .string("x"), .whitespace, .closeParen])
    #expect(CSSTokenizer.tokenize("ur/**/l(x)") == [.ident("ur"), .function("l"), .ident("x"), .closeParen])
}

@Test func tokenizerHandlesNumbersAndDimensions() {
    #expect(CSSTokenizer.tokenize("10px 1.5em -2 50% 1e3") == [
        .dimension("10", unit: "px"), .whitespace, .dimension("1.5", unit: "em"), .whitespace, .number("-2"), .whitespace,
        .percentage("50"), .whitespace, .number("1e3"),
    ])
}

@Test func tokenizerBadURLAndBadString() {
    #expect(CSSTokenizer.tokenize("url(a b)") == [.badURL])
    #expect(CSSTokenizer.tokenize("\"abc\nd") == [.badString, .whitespace, .ident("d")])
}

@Test func serializerRoundTrips() {
    let samples = [
        "p{color:red}", "a:hover{text-decoration:underline !important}", "@media (max-width:600px){.x{width:100%}}",
        "div{font-family:\"Helvetica Neue\",Arial,sans-serif;margin:0 auto}", "#\\31 23{color:#fff}",
        "x{background:url(\"ohcid:a@b\")}", "-x-y{a:1e\\33 }",
    ]
    for css in samples {
        let tokens = CSSTokenizer.tokenize(css)
        let again = CSSTokenizer.tokenize(CSSSerializer.serialize(tokens))
        #expect(again == tokens, "\(css) -> \(CSSSerializer.serialize(tokens))")
    }
}

@Test func serializerSeparatesTokensThatWouldMerge() {
    let tokens: [CSSToken] = [.ident("ur"), .function("l")]
    #expect(CSSSerializer.serialize(tokens) == "ur/**/l(")
    #expect(CSSSerializer.serialize([.ident("a"), .openParen]) == "a/**/(")
    #expect(CSSSerializer.serialize([.number("1"), .ident("px")]) == "1/**/px")
}

@Test func serializerNeverEmitsTagOpeners() {
    let css = CSSSerializer.serialize([.string("</style><script>"), .delim("<"), .ident("<x"), .cdo, .cdc])
    #expect(!css.contains("<"))
}

@Test func declarationSanitizer() {
    var s = CSSSanitizer(allowRemoteImages: false)
    #expect(s.sanitizeDeclarations("color: red; behavior: url(x.htc); width: expression(1)") == "color:red")
    #expect(s.sanitizeDeclarations("background: #fff url(https://e.example/a.png); color: blue") == "color:blue")
    #expect(s.stats.blockedRemote == 1)
    #expect(s.sanitizeDeclarations("position:sticky;margin:0") == "margin:0")
    #expect(s.sanitizeDeclarations("a { color: red }") == "")
    #expect(s.sanitizeDeclarations("font-family: 'Helvetica Neue', Arial") == "font-family:\"Helvetica Neue\", Arial")
}

@Test func stylesheetSanitizerDropsDangerousAtRules() {
    var s = CSSSanitizer(allowRemoteImages: false)
    let out = s.sanitizeStylesheet("@charset 'x'; @import url(a.css); @namespace x url(y); @page { margin: 0 } p { color: red }")
    #expect(out == "p{color:red}")
}

@Test func deeplyNestedMediaIsCut() {
    var css = "p{color:red}"
    for _ in 0..<20 { css = "@media screen{" + css + "}" }
    var s = CSSSanitizer(allowRemoteImages: false)
    #expect(!s.sanitizeStylesheet(css).contains("color"))
}

@Test func selectorScopingCases() {
    func scoped(_ css: String) -> String {
        var s = CSSSanitizer(allowRemoteImages: false, scopeSelectors: true)
        return s.sanitizeStylesheet(css)
    }
    #expect(scoped("body{margin:0}") == ".oh-body{margin:0}")
    #expect(scoped("BODY.dark > td{x:1}") == ".oh-body.dark > td{x:1}")
    #expect(scoped("html body p, :root{x:1}") == ".oh-body p,.oh-body{x:1}")
    #expect(scoped("*{x:1}") == ".oh-body *{x:1}")
    #expect(scoped("a:hover, .x .y{x:1}") == ".oh-body a:hover,.oh-body .x .y{x:1}")
    #expect(scoped(".a:not(body){x:1}") == ".oh-body .a:not(body){x:1}")
    #expect(scoped("p, {x:1}") == "", "an empty selector in a list drops the rule")
    #expect(scoped("#OH-root{x:1} [data-x=\"oh-y\"]{x:1}") == "")
    #expect(scoped("@media print{body{x:1}}") == "@media print{.oh-body{x:1}}")
}

@Test func unitsStartingWithEKeepTheirMeaning() {
    for css in ["a{font-size:2em}", "a{width:3ex}", "a{x:1e\\33 }", "a{x:1e\\2d 2}", "a{x:5\\65 }"] {
        let tokens = CSSTokenizer.tokenize(css)
        let again = CSSTokenizer.tokenize(CSSSerializer.serialize(tokens))
        #expect(again == tokens, "\(css) -> \(CSSSerializer.serialize(tokens))")
    }
    #expect(CSSSerializer.serialize(CSSTokenizer.tokenize("a{font-size:2em}")) == "a{font-size:2em}")
}

@Test func deeplyNestedFunctionsArePoisonedNotRecursed() {
    var s = CSSSanitizer(allowRemoteImages: false)
    let css = "width:" + String(repeating: "calc(", count: 5_000) + "1px" + String(repeating: ")", count: 5_000) + ";color:red"
    #expect(s.sanitizeDeclarations(css) == "color:red")
}
