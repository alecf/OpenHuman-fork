import MailTheme

extension ThemeTokens {
    func listZoomed(_ zoom: Double) -> ThemeTokens {
        guard zoom > 0, zoom != 1 else { return self }
        var tokens = self
        func scale(_ style: inout TypeStyle) {
            style.size = (style.size * zoom * 2).rounded() / 2
            style.lineHeight = (style.lineHeight * zoom).rounded()
        }
        scale(&tokens.typeBody)
        scale(&tokens.typeBodyStrong)
        scale(&tokens.typeMeta)
        scale(&tokens.typeCaption)
        scale(&tokens.typeHeadline)
        tokens.densityCompactRow = (densityCompactRow * zoom).rounded()
        tokens.densityDefaultRow = (densityDefaultRow * zoom).rounded()
        tokens.densityComfortableRow = (densityComfortableRow * zoom).rounded()
        return tokens
    }
}
