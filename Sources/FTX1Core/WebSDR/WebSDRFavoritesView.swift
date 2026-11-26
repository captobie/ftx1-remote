import SwiftUI

/// "Manage Favorites…" from the WebSDR window's Favorites menu: rename,
/// reorder (drag), and remove saved stations. Adding happens elsewhere —
/// the star next to the host field, or the Stations sheet's star column.
public struct WebSDRFavoritesView: View {
    @ObservedObject public var model: WebSDRFollowModel

    public init(model: WebSDRFollowModel) {
        self.model = model
    }
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
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
                    ContentUnavailableView(String(localized: "webSDRFavorites.noFavorites", bundle: .module), systemImage: "star",
                                           description: Text(String(localized: "webSDRFavorites.starAStationTo", bundle: .module)))
                }
            }
            Divider()
            HStack {
                Text(String(localized: "webSDRFavorites.clickANameTo", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // Escape, not Return: Return belongs to the name fields
                // (it commits a rename) and mustn't also close the sheet.
                Button(String(localized: "common.done", bundle: .module)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 320)
        #endif
    }

    /// Name is editable in place (committed on Return or when the sheet closes); host,
    /// location and range underneath for telling similar names apart.
    private struct FavoriteRow: View {
        let favorite: WebSDRFavorite
        let onRename: (String) -> Void
        let onRemove: () -> Void
        @State private var name: String
        @FocusState private var nameFocused: Bool

        init(favorite: WebSDRFavorite, onRename: @escaping (String) -> Void,
             onRemove: @escaping () -> Void) {
            self.favorite = favorite
            self.onRename = onRename
            self.onRemove = onRemove
            _name = State(initialValue: favorite.name)
        }

        private var details: String {
            var parts = [favorite.platform?.displayName, favorite.hostPort].compactMap { $0 }
            if !favorite.location.isEmpty { parts.append(favorite.location) }
            let unknownRange = favorite.platform == .webSDR ? String(localized: "webSDRFavorites.rangeReadOnNext", bundle: .module) : String(localized: "webSDRFavorites.030MHzRange", bundle: .module)
            parts.append(favorite.bandRanges.map { $0.map(KiwiSDRStation.describe).joined(separator: ", ") }
                         ?? unknownRange)
            return parts.joined(separator: " · ")
        }

        var body: some View {
            HStack {
                fields
                Button(action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "common.removeFromFavorites", bundle: .module))
            }
        }

        private var fields: some View {
            VStack(alignment: .leading, spacing: 2) {
                TextField(String(localized: "common.name", bundle: .module), text: $name)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    // The field spans the row but inside a List only takes
                    // clicks on its text; until it's editing, this layer
                    // takes every click on the line and focuses it instead.
                    .overlay {
                        if !nameFocused {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { nameFocused = true }
                        }
                    }
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
            // Clicks on the details line (or anywhere else in the row
            // besides the trash button) edit the name too.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { nameFocused = true }
        }
    }
}
