import SwiftUI

/// "Manage Favorites…" from the WebSDR window's Favorites menu: rename,
/// reorder (drag), and remove saved stations. Adding happens elsewhere —
/// the star next to the host field, or the Stations sheet's star column.
struct WebSDRFavoritesView: View {
    @ObservedObject var model: WebSDRFollowModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No row selection: in a selectable List a click selects the
            // row instead of starting to edit its name field. Removing is a
            // per-row button instead.
            List {
                ForEach(model.favorites) { favorite in
                    FavoriteRow(favorite: favorite,
                                onRename: { model.renameFavorite(id: favorite.id, to: $0) },
                                onRemove: { model.removeFavorite(hostPort: favorite.hostPort) })
                }
                .onMove(perform: model.moveFavorites)
            }
            .overlay {
                if model.favorites.isEmpty {
                    ContentUnavailableView("No Favorites", systemImage: "star",
                                           description: Text("Star a station to add it."))
                }
            }
            Divider()
            HStack {
                Text("Click a name to rename it; drag to reorder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // Escape, not Return: Return belongs to the name fields
                // (it commits a rename) and mustn't also close the sheet.
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
        }
        .frame(minWidth: 520, minHeight: 320)
    }

    /// Name is editable in place (committed on Return or when the sheet closes); host,
    /// location and range underneath for telling similar names apart.
    private struct FavoriteRow: View {
        let favorite: WebSDRFavorite
        let onRename: (String) -> Void
        let onRemove: () -> Void
        @State private var name: String

        init(favorite: WebSDRFavorite, onRename: @escaping (String) -> Void,
             onRemove: @escaping () -> Void) {
            self.favorite = favorite
            self.onRename = onRename
            self.onRemove = onRemove
            _name = State(initialValue: favorite.name)
        }

        private var details: String {
            var parts = [favorite.hostPort]
            if !favorite.location.isEmpty { parts.append(favorite.location) }
            parts.append(favorite.bandRanges.map { $0.map(KiwiSDRStation.describe).joined(separator: ", ") }
                         ?? "0–30 MHz (range unknown)")
            return parts.joined(separator: " · ")
        }

        var body: some View {
            HStack {
                fields
                Button(action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove from Favorites")
            }
        }

        private var fields: some View {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    // Full row width, so clicking beside a short name still edits it.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onSubmit { onRename(name) }
                    .onChange(of: favorite.name) { _, newName in name = newName }
                    // Done/close without Return still keeps the edit.
                    .onDisappear { if name != favorite.name { onRename(name) } }
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.vertical, 2)
        }
    }
}
