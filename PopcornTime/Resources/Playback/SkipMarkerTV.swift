#if os(tvOS)
import UIKit
import PopcornKit

/// « Skip Intro » over the Apple TV's VLC player (`PCTPlayerViewController`;
/// the native player uses AVKit's contextual action): a focused button at
/// the bottom right, the video playing on, unobscured, behind it. Select
/// skips, Menu puts the button away for this part, Play/Pause goes to the
/// player (`onPlayPause`).
final class SkipMarkerOverlayViewController: UIViewController {
    let watch: SkipMarkerWatch
    var onPlayPause: (() -> Void)?
    private let button = UIButton(type: .system)

    init(watch: SkipMarkerWatch) {
        self.watch = watch
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { return nil }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [button] }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: "forward.end.fill")
        configuration.imagePadding = 12
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 18, leading: 34, bottom: 18, trailing: 34)
        configuration.cornerStyle = .capsule
        button.configuration = configuration
        button.setTitle(watch.active?.kind.buttonTitle, for: .normal)
        button.accessibilityIdentifier = "skipMarkerButton"
        button.addTarget(self, action: #selector(skip), for: .primaryActionTriggered)
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40),
        ])
    }

    /// The part offered changed (recap → intro): the title follows.
    func update(_ marker: SkipMarker) {
        loadViewIfNeeded()
        button.setTitle(marker.kind.buttonTitle, for: .normal)
    }

    @objc private func skip() { watch.skip() }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) { return watch.dismissOffer() }
        if presses.contains(where: { $0.type == .playPause }) { return onPlayPause?() ?? () }
        super.pressesBegan(presses, with: event)
    }

    // Menu's and Play/Pause's other phases stay here (the player under it would act on them).
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard !presses.contains(where: { $0.type == .menu || $0.type == .playPause }) else { return }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard !presses.contains(where: { $0.type == .menu || $0.type == .playPause }) else { return }
        super.pressesCancelled(presses, with: event)
    }
}
#endif
