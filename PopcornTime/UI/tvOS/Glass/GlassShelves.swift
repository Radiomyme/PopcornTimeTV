// GlassShelves.swift — lower sections of the glass detail page: "Viewers Also
// Watched" posters, "Cast & Crew" headshots, and the Information /
// Accessibility cards.
import SwiftUI

/// Section title, aligned with the page's content inset.
struct GlassSectionHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(GlassFont.sectionTitle)
            .foregroundStyle(GlassPalette.primaryText)
            .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
            .padding(.horizontal, GlassMetrics.sideInset)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Viewers Also Watched

struct GlassRelatedShelf: View {
    let items: [GlassRelatedItem]
    let isLoading: Bool
    var focus: FocusState<GlassFocusTarget?>.Binding
    let open: (String) -> Void

    static let posterWidth: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GlassSectionHeader(title: "Viewers Also Watched")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 44) {
                    if items.isEmpty && isLoading {
                        ForEach(0..<7, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                                .frame(width: Self.posterWidth, height: Self.posterWidth * 1.5)
                        }
                    }
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 0) {
                            SwiftUI.Button { open(item.id) } label: {
                                GlassRemoteImage(url: item.posterURL, maxPixelSize: Self.posterWidth * 2) {
                                    posterPlaceholder(item.title)
                                }
                                .frame(width: Self.posterWidth, height: Self.posterWidth * 1.5)
                                .clipped()
                            }
                            .glassCardStyle()
                            .focused(focus, equals: .related(item.id))
                            .accessibilityLabel(Text(verbatim: item.title))

                            Text(verbatim: item.title)
                                .font(GlassFont.captionBold)
                                .foregroundStyle(GlassPalette.primaryText)
                                .lineLimit(1)
                                .padding(.top, 22)
                            if let subtitle = item.subtitle {
                                Text(verbatim: subtitle)
                                    .font(GlassFont.small)
                                    .foregroundStyle(GlassPalette.tertiaryText)
                                    .lineLimit(1)
                                    .padding(.top, 4)
                            }
                        }
                        .frame(width: Self.posterWidth, alignment: .leading)
                    }
                }
                .padding(.vertical, 30)
            }
            .contentMargins(.horizontal, GlassMetrics.sideInset, for: .scrollContent)
            .scrollClipDisabled()
            .focusSection()
        }
        .padding(.top, GlassMetrics.topInset)
    }

    private func posterPlaceholder(_ title: String) -> some View {
        ZStack {
            LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.05)],
                           startPoint: .top, endPoint: .bottom)
            Text(verbatim: title)
                .font(GlassFont.captionBold)
                .foregroundStyle(GlassPalette.secondaryText)
                .multilineTextAlignment(.center)
                .padding(18)
        }
    }
}

// MARK: - Cast & Crew

struct GlassCastShelf: View {
    let people: [GlassPerson]
    let isLoading: Bool
    var focus: FocusState<GlassFocusTarget?>.Binding
    let open: (String) -> Void

    static let headshot: CGFloat = 176

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GlassSectionHeader(title: "Cast & Crew")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 36) {
                    if people.isEmpty && isLoading {
                        ForEach(0..<8, id: \.self) { _ in
                            Circle()
                                .fill(Color.white.opacity(0.08))
                                .frame(width: Self.headshot, height: Self.headshot)
                                .frame(width: 214)
                        }
                    }
                    ForEach(people) { person in
                        SwiftUI.Button { open(person.id) } label: {
                            GlassPersonLockup(person: person, size: Self.headshot)
                        }
                        .buttonStyle(GlassCircleButtonStyle())
                        .focused(focus, equals: .person(person.id))
                    }
                }
                .padding(.vertical, 34)
            }
            .contentMargins(.horizontal, GlassMetrics.sideInset, for: .scrollContent)
            .scrollClipDisabled()
            .focusSection()
        }
        .padding(.top, GlassMetrics.topInset)
    }
}

/// Round headshot (or monogram on glass) with name and role.
struct GlassPersonLockup: View {
    let person: GlassPerson
    let size: CGFloat
    @Environment(\.glassItemFocused) private var isFocused

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Text(verbatim: person.initials)
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(width: size, height: size)
                    .glassSurface(Circle(), fallback: .thinMaterial)
                if person.imageURL != nil {
                    GlassRemoteImage(url: person.imageURL, maxPixelSize: size * 2) { Color.clear }
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                }
            }
            .overlay {
                Circle().stroke(Color.white.opacity(isFocused ? 0.95 : 0.18), lineWidth: isFocused ? 5 : 1.5)
            }
            .shadow(color: .black.opacity(isFocused ? 0.5 : 0.25), radius: isFocused ? 24 : 10, y: isFocused ? 16 : 6)

            VStack(spacing: 4) {
                Text(verbatim: person.name)
                    .font(GlassFont.captionBold)
                    .foregroundStyle(GlassPalette.primaryText)
                if let role = person.role, !role.isEmpty {
                    Text(verbatim: role)
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(isFocused ? GlassPalette.secondaryText : GlassPalette.tertiaryText)
                }
            }
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(width: 214)
        }
        .frame(width: 214)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Information / Accessibility

struct GlassInfoSection: View {
    let information: [GlassInfoRow]
    let accessibility: [GlassInfoRow]
    var focus: FocusState<GlassFocusTarget?>.Binding

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            if !information.isEmpty {
                card(title: "Information", rows: information)
                    .focused(focus, equals: .information)
            }
            if !accessibility.isEmpty {
                card(title: "Accessibility", rows: accessibility)
                    .focused(focus, equals: .accessibility)
            }
        }
        .fixedSize(horizontal: false, vertical: true)   // both cards take the taller height
        .padding(.horizontal, GlassMetrics.sideInset)
        .padding(.top, GlassMetrics.topInset + 10)
        .focusSection()
    }

    /// Focusable so the focus engine can scroll down to it; pressing does nothing.
    private func card(title: LocalizedStringKey, rows: [GlassInfoRow]) -> some View {
        SwiftUI.Button {} label: {
            VStack(alignment: .leading, spacing: 24) {
                Text(title)
                    .font(.system(size: 31, weight: .bold))
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 34, verticalSpacing: 16) {
                    ForEach(rows) { row in
                        GridRow {
                            Text(verbatim: row.key)
                                .font(GlassFont.captionBold)
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.leading)
                            Text(verbatim: row.value)
                                .font(.system(size: 27, weight: .regular))
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 34)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .buttonStyle(GlassCardButtonStyle(focusScale: 1.015))
    }
}
