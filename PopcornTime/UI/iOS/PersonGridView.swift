import SwiftUI
import PopcornKit

/// A cast or crew member's page (`CatalogRoute.person`): their movies and
/// shows from TMDB, the most watched first, as the catalogue's posters.
/// Opened from a title's « Cast & Crew » when a TMDB key is set.
struct PersonGridView: View {
    let person: Actor

    @State private var titles: [Media]?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        PosterGridReader { metrics in
            ScrollView {
                if let titles {
                    if titles.isEmpty {
                        ContentUnavailableView {
                            Text("No results")
                        } description: {
                            Text(String.localizedStringWithFormat("We didn't turn anything up for %@. Try something else.".localized,
                                                                  person.name.quotedForDisplay()))
                        }
                        .padding(.top, 60)
                    } else {
                        LazyVGrid(columns: metrics.columns, alignment: .leading, spacing: PosterGrid.lineSpacing) {
                            ForEach(titles, id: \.id) { media in
                                if let route = MediaRoute(media: media, zoomID: "person/\(media.id)") {
                                    NavigationLink(value: route) {
                                        PosterCard(item: GridCard.item(media), size: metrics.cellSize, zoomID: "person/\(media.id)", media: media)
                                    }
                                    .buttonStyle(HomeCardButtonStyle())
                                }
                            }
                        }
                        .padding(.horizontal, metrics.sideInset)
                        .padding(.top, 8)
                    }
                } else {
                    ProgressView().padding(.top, 60)
                }
            }
            .scrollTopShade()
        }
        .navigationTitle(Text(verbatim: person.name))
        .navigationBarTitleDisplayMode(horizontalSizeClass == .regular ? .inline : .large)
        .accessibilityIdentifier("Person.\(person.imdbId)")
        .task(id: person.imdbId) {
            guard titles == nil else { return }
            DetailExtras.titles(of: person) { titles = $0 ?? [] }
        }
    }
}
