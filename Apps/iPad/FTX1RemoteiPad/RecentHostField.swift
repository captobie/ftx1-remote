import SwiftUI

/// A hostname field that remembers the hosts this route has connected to
/// (desktop hubs on one screen, Pis on the other), so switching between
/// several computers or Pis doesn't mean retyping. While the field has
/// focus, a list of them drops down under it: tap a row to fill the field
/// (connecting stays the Connect button's job), or its ✕ to forget it.
struct RecentHostField: View {
    let placeholder: String
    @Binding var host: String
    /// Newest first; `RecentHosts.remember`/`forget` keep it that way.
    @Binding var recentHosts: [String]

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $host)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($isFocused)
            .onSubmit { isFocused = false }
            // Hung just under the field. An overlay takes no layout space,
            // so nothing below moves; the row holding this field needs
            // `.zIndex(1)` so the list draws over the rows after it.
            .overlay {
                GeometryReader { proxy in
                    if isFocused && !recentHosts.isEmpty {
                        list
                            .frame(width: proxy.size.width)
                            .offset(y: proxy.size.height + 4)
                    }
                }
            }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(recentHosts, id: \.self) { recent in
                HStack(spacing: 8) {
                    Button {
                        host = recent
                        isFocused = false
                    } label: {
                        HStack {
                            Text(recent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                            if recent == host {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        recentHosts = RecentHosts.forget(recent, in: recentHosts)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .imageScale(.large)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("recentHostField.forget \(recent)")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                if recent != recentHosts.last {
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

/// Remembered hosts, stored in `@AppStorage` as one newline-separated
/// string (hostnames can't contain a newline).
enum RecentHosts {
    static let hubKey = "hubHost.recent"
    static let piKey = "piHost.recent"
    /// Oldest ones drop off past this.
    static let limit = 10

    static func decode(_ raw: String) -> [String] {
        raw.split(separator: "\n").map(String.init)
    }

    static func encode(_ hosts: [String]) -> String {
        hosts.joined(separator: "\n")
    }

    /// Moves `host` to the front (case-insensitive match, newest spelling
    /// kept).
    static func remember(_ host: String, in hosts: [String]) -> [String] {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return hosts }
        let rest = hosts.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        return Array(([trimmed] + rest).prefix(limit))
    }

    static func forget(_ host: String, in hosts: [String]) -> [String] {
        hosts.filter { $0 != host }
    }
}

extension Binding where Value == String {
    /// `[String]` view of a `RecentHosts`-encoded `@AppStorage` string.
    var recentHostList: Binding<[String]> {
        Binding<[String]>(
            get: { RecentHosts.decode(wrappedValue) },
            set: { wrappedValue = RecentHosts.encode($0) }
        )
    }
}
