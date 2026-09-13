// macspanso/Views/UndoDeleteBanner.swift
import SwiftUI

/// Shown after a delete, for a short grace period, so an accidental delete
/// (single match or a multi-select batch) can be reversed. Modeled directly
/// on ExternalEditBanner's shape; the two share the same overlay slot in
/// MatchManagerView and are mutually exclusive.
struct UndoDeleteBanner: View {
    let label: String
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash")
                .foregroundStyle(Color.accentColor)
            Text(label)
                .font(.callout)
            Spacer()
            Button("Undo", action: onUndo)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
