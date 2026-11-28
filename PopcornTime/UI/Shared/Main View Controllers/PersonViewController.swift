

import Foundation
import PopcornKit

class PersonViewController: MainViewController {
    
    var currentItem: Person!
    
    // tvOS Exclusive
    
    @IBOutlet var titleLabel: UILabel?
    
    override func viewDidLoad() {
        // Set the title BEFORE super.viewDidLoad so MainViewController's
        // installInBodyHeader (called from super) reads the actor name and
        // displays it in the in-body header rather than the storyboard
        // placeholder text.
        navigationItem.title = currentItem.name

        super.viewDidLoad()

        titleLabel?.text = currentItem.name
        collectionViewController.paginated = false
    }
    
    override func load(page: Int) {
        guard !collectionViewController.isLoading else { return }
        collectionViewController.isLoading = true
        // Their movies and shows from TMDB (Trakt, which gave them, refuses
        // the app's key): nothing without a TMDB key, and the page says so.
        DetailExtras.titles(of: currentItem) { [weak self] titles in
            guard let self else { return }
            self.collectionViewController.dataSources[0] += (titles ?? []).compactMap { $0 as? AnyHashable }
            self.collectionViewController.dataSources[0].unique()
            self.collectionViewController.isLoading = false
            self.collectionView?.reloadData()
        }
    }
    
    override func collectionView(isEmptyForUnknownReason collectionView: UICollectionView) {
        collectionViewController.showMessage(title: "No results".localized,
                                             body: .localizedStringWithFormat("We didn't turn anything up for %@. Try something else.".localized, currentItem.name.quotedForDisplay()))
    }
}
