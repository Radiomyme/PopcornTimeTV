// HomeServiceTile.swift — the « Services » row of the Home (iOS and macOS)
// and what a page filtered on a service shows instead of its shelves.
//
// A card of the row is not a title (`HomeServiceCard`): a 16:9 tile with the
// service's logo from TMDB's image host — its name when the stored service
// has no logo — « All » first while the page is filtered, the service shown
// checked and captioned « Selected ». Picking it filters the page through
// the page's own hub (`HomeState.pick(service:)`); it has no menu, no
// watchlist action, no « See All », and no poster from another host.
import Foundation
import SwiftUI
import PopcornKit

/// One card of the « Services » row, at the size of the row's landscape
/// cards (`HomeLayout`), so the row lines up with the others.
struct HomeServiceTile: View {
    let item: HomeItem
    let layout: HomeLayout

    @Environment(\.displayScale) private var displayScale

    private var isSelected: Bool { HomeServiceCard.isSelected(item) }

    var body: some View {
        let size = CGSize(width: layout.landscapeWidth, height: layout.landscapeHeight)
        VStack(alignment: .leading, spacing: homeCaptionGap) {
            face(size: size)
                .homeCardLift(corner: layout.cardCorner)
            HomeCardCaption(title: item.title) {
                Text(verbatim: isSelected ? "Home.Services.Shown".localized : " ")
            }
        }
        .frame(width: size.width, alignment: .leading)
    }

    private func face(size: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: layout.cardCorner, style: .continuous)
        // The logo: a square, a little over half the tile's height.
        let logo = (size.height * 0.56).rounded()
        return ZStack {
            LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.05)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if HomeServiceCard.isAll(item) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: (size.height * 0.3).rounded(), weight: .semibold))
                    .foregroundStyle(GlassPalette.primaryText)
            } else if let url = item.posterURL {
                HomeArtwork(urls: [url], maxPixelSize: (logo * displayScale).rounded(.up)) { failed in
                    if failed { name(size: size) } else { Color.clear }
                }
                .frame(width: logo, height: logo)
                .clipShape(RoundedRectangle(cornerRadius: (logo * 0.2).rounded(), style: .continuous))
            } else {
                name(size: size)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(shape.stroke(isSelected ? Color.white.opacity(0.7) : HomePalette.hairline, lineWidth: isSelected ? 2 : 1))
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: (size.height * 0.17).rounded(), weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.black, .white)
                    .padding(8)
            }
        }
    }

    /// The service's name, when there is no logo (or it does not load).
    private func name(size: CGSize) -> some View {
        Text(verbatim: item.title)
            .font(.system(size: (size.height * 0.16).rounded(), weight: .heavy))
            .foregroundStyle(GlassPalette.primaryText)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 12)
    }
}

/// The page filtered on a service has no shelf yet: placeholders while its
/// lists are on their way, « No results » when it listed nothing, its own
/// message and Try Again when its lists failed (`HomeServicePage`). Drawn
/// under the « Services » row, which stays: « All » and the other services
/// are a tap away.
struct HomeServiceState: View {
    let page: HomeServicePage
    let layout: HomeLayout
    let text: HomeCardText
    let retry: () -> Void

    /// Where to check a refused key, by the name this app's Settings show:
    /// the Mac's tab is « Streaming », the iPhone's section « Services de
    /// streaming ».
    static var refusedKey: LocalizedStringKey {
        #if os(macOS)
        return "Grid.Service.Refused.Mac"
        #else
        return "Grid.Service.Refused"
        #endif
    }

    var body: some View {
        switch page {
        case .loading:
            VStack(alignment: .leading, spacing: layout.shelfSpacing) {
                HomeShelfSkeleton(style: .posters, layout: layout, text: text)
                HomeShelfSkeleton(style: .posters, layout: layout, text: text)
            }
            .modifier(HomePulse())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Spinner.Loading"))
            .accessibilityIdentifier("Home.Services.Loading")
        case .empty:
            Text("No results")
                .font(HomeFont.cardTitle)
                .foregroundStyle(GlassPalette.secondaryText)
                .padding(.horizontal, layout.sideInset)
                .accessibilityIdentifier("Home.Services.Empty")
        case .failed(let service, let refused):
            ContentUnavailableView {
                Label(String(format: "Home.Unavailable.Service".localized, service),
                      systemImage: refused ? "lock.slash" : "wifi.exclamationmark")
            } description: {
                Text(refused ? HomeServiceState.refusedKey : "Grid.Service.Unavailable")
            } actions: {
                Button("Try Again", action: retry)
                    .glassActionStyle(prominent: true)
                    .accessibilityIdentifier("Home.Retry")
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, layout.sideInset)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(refused ? "Home.Services.Refused" : "Home.Services.Unavailable")
        case .usual, .shelves:
            EmptyView()
        }
    }
}
