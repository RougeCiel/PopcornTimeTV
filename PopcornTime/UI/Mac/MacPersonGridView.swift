import SwiftUI
import PopcornKit

/// A cast or crew member's page (`MacRoute.person`): their movies and shows
/// from TMDB, the most watched first, as the catalogue's posters. Opened
/// from a title's « Cast & Crew » when a TMDB key is set.
struct MacPersonGridView: View {
    let person: Actor

    @State private var titles: [Media]?
    @State private var width = MacPosterGrid.defaultWidth

    var body: some View {
        let grid = MacPosterGrid(width: width)
        ScrollView {
            MacPageTitle(title: Text(verbatim: person.name), sideInset: grid.sideInset)
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
                    LazyVGrid(columns: grid.columns, alignment: .leading, spacing: MacPosterGrid.rowSpacing) {
                        ForEach(titles, id: \.id) { media in
                            if let movie = media as? Movie {
                                MacPosterLink(item: movie, size: grid.cellSize)
                            } else if let show = media as? Show {
                                MacPosterLink(item: show, size: grid.cellSize)
                            }
                        }
                    }
                    .padding(.horizontal, grid.sideInset)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                }
            } else {
                ProgressView().controlSize(.small).padding(.top, 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .macGridWidth($width)
        .macPageBackground()
        .navigationTitle(Text(verbatim: person.name))
        .modifier(MacNoBarTitle())
        .accessibilityIdentifier("Person.\(person.imdbId)")
        .task(id: person.imdbId) {
            guard titles == nil else { return }
            DetailExtras.titles(of: person) { titles = $0 ?? [] }
        }
    }
}
