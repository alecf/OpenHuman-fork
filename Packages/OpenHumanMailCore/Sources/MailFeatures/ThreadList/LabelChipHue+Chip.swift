import MailTheme

extension ThreadRowChip {
    public var hue: LabelChipHue {
        switch kind {
        case .important, .gmailImportant, .vip, .overflow, .returned:
            .neutral
        case .category:
            isFallback ? .neutral : LabelChipHue.category(title)
        case .label:
            color.flatMap(LabelChipHue.nearest(toHex:)) ?? LabelChipHue.forName(title)
        }
    }
}
