import AppKit
import SwiftUI

/// Grouped forms align SwiftUI value fields to the trailing edge. Keep address
/// entry leading-aligned, and avoid replacing equal text in its live field editor.
struct EarthAddressField: NSViewRepresentable
{
    let text: String
    let onChange: (String) -> Void
    let onSubmit: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange, onSubmit: onSubmit) }

    func makeNSView(context: Context) -> NSTextField
    {
        let field = NSTextField(string: text)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.placeholderString = "Street address"
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.alignment = .left
        field.setAccessibilityLabel("Address")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.cell?.sendsActionOnEndEditing = false
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context)
    {
        context.coordinator.onChange = onChange
        context.coordinator.onSubmit = onSubmit
        field.isEnabled = isEnabled
        if field.stringValue != text { field.stringValue = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize?
    {
        CGSize(width: proposal.width ?? 180, height: nsView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate
    {
        var onChange: (String) -> Void
        var onSubmit: () -> Void

        init(onChange: @escaping (String) -> Void, onSubmit: @escaping () -> Void)
        {
            self.onChange = onChange
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ notification: Notification)
        {
            if let field = notification.object as? NSTextField { onChange(field.stringValue) }
        }

        @objc func submit(_ sender: NSTextField) { onSubmit() }
    }
}
