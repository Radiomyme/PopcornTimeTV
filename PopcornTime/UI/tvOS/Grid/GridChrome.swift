// GridChrome.swift — what an Apple TV poster grid shows besides its posters:
// the header (page title, Sort / Genre), the loading placeholders, the empty
// and error messages with Retry, and the footer of a list that is still
// loading or could not load its next page.
import UIKit

// MARK: - Header

/// One line: the page title on the left edge of the rows, the controls on
/// the right. A control says what it is set to ("Sort: Trending"), so the
/// page never needs a second line to say which list it shows.
final class GridHeaderView: UIView {

    let titleLabel = UILabel()
    private let controls = UIStackView()
    /// Over the header, left of the controls: Up from any poster of the
    /// first row lands on the first control (the focus engine went straight
    /// to the tab bar from the columns far from them). On only while the
    /// focus is in the grid.
    let focusGuide = UIFocusGuide()

    var buttons: [UIButton] { return controls.arrangedSubviews.compactMap { $0 as? UIButton } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = GridStyle.pageTitleFont
        titleLabel.textColor = GridStyle.primaryText
        titleLabel.accessibilityIdentifier = "GridHeader.Title"
        titleLabel.accessibilityTraits = .header
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        controls.axis = .horizontal
        controls.spacing = 20
        controls.alignment = .center
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)

        focusGuide.isEnabled = false
        addLayoutGuide(focusGuide)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor, constant: -40),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor),
            controls.centerYAnchor.constraint(equalTo: centerYAnchor),
            focusGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            focusGuide.trailingAnchor.constraint(equalTo: controls.leadingAnchor),
            focusGuide.topAnchor.constraint(equalTo: topAnchor),
            focusGuide.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Adds a control (a capsule that opens a list of choices).
    @discardableResult
    func addControl(identifier: String, target: Any?, action: Selector) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 26, bottom: 11, trailing: 22)
        configuration.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold))
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 12
        let button = UIButton(configuration: configuration)
        button.addTarget(target, action: action, for: .primaryActionTriggered)
        button.accessibilityIdentifier = identifier
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        controls.addArrangedSubview(button)
        if focusGuide.preferredFocusEnvironments.isEmpty { focusGuide.preferredFocusEnvironments = [button] }
        return button
    }

    /// The control opens `menu` where it is (its own action no longer
    /// presents an alert).
    static func setMenu(_ button: UIButton?, _ menu: UIMenu) {
        guard let button, !menu.children.isEmpty else { return }
        button.removeTarget(nil, action: nil, for: .primaryActionTriggered)
        button.menu = menu
        button.showsMenuAsPrimaryAction = true
    }

    /// "Sort: Trending": `format` is the localized "Sort: %@", `value` what
    /// the control is set to. The name is dimmed, the value is what is read.
    static func set(_ button: UIButton?, format: String, value: String) {
        guard let button = button else { return }
        let text = String(format: format, value)
        button.accessibilityLabel = text
        let valueRange = (text as NSString).range(of: value, options: .backwards)
        button.configurationUpdateHandler = { button in
            // The system draws a focused button light: dark text on it.
            let focused = button.isFocused
            let strong = focused ? UIColor.black : GridStyle.primaryText
            let dim = focused ? UIColor(white: 0, alpha: 0.6) : GridStyle.secondaryText
            let title = NSMutableAttributedString(string: text, attributes: [.font: GridStyle.controlFont, .foregroundColor: dim])
            if valueRange.location != NSNotFound { title.addAttribute(.foregroundColor, value: strong, range: valueRange) }
            var configuration = button.configuration
            configuration?.attributedTitle = AttributedString(title)
            configuration?.baseForegroundColor = dim
            button.configuration = configuration
        }
        button.setNeedsUpdateConfiguration()
    }
}

// MARK: - A section's title

/// The title of a section of a grid (Watchlist: Movies, Shows), on the
/// rows' left edge.
final class GridSectionTitleView: UICollectionReusableView {

    static let reuseIdentifier = "gridSectionTitle"

    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = GridStyle.sectionTitleFont
        label.textColor = GridStyle.primaryText
        label.accessibilityTraits = .header
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // At the bottom of its header: any extra height is room above it.
        label.frame = CGRect(x: GridStyle.sideInset, y: bounds.height - GridStyle.sectionTitleHeight,
                             width: bounds.width - GridStyle.sideInset * 2, height: GridStyle.sectionTitleHeight)
    }
}

// MARK: - Loading placeholders

/// A grid waiting for its first titles with nothing saved to paint: cards
/// of the posters' size where the first rows will be. No spinner, and
/// nothing moves when the posters take their place.
final class GridSkeletonView: UIView {

    /// From the view's top to the first row (the grid's top inset and its
    /// first section's).
    var top: CGFloat = 0 { didSet { if top != oldValue { setNeedsLayout() } } }
    /// Between two cards of a row, and from a row's cards to the next ones':
    /// the grid's, or the rows' (`CollectionViewController.layOutAsRows`).
    var columnSpacing = GridStyle.columnSpacing { didSet { setNeedsLayout() } }
    var rowSpacing = GridStyle.rowSpacing { didSet { setNeedsLayout() } }

    private var cards: [CALayer] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityIdentifier = "Grid.Loading"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = GridStyle.posterSize
        let columns = max(1, Int((bounds.width - GridStyle.sideInset * 2 + columnSpacing) / (size.width + columnSpacing)))
        let rows = max(1, Int(ceil((bounds.height - top) / (size.height + rowSpacing))))
        let wanted = columns * rows
        while cards.count < wanted {
            let card = CALayer()
            card.backgroundColor = GridStyle.placeholderFill.cgColor
            card.cornerRadius = 12
            card.cornerCurve = .continuous
            layer.addSublayer(card)
            cards.append(card)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, card) in cards.enumerated() {
            card.isHidden = index >= wanted
            let column = CGFloat(index % columns), row = CGFloat(index / columns)
            card.frame = CGRect(x: GridStyle.sideInset + column * (size.width + columnSpacing),
                                y: top + row * (size.height + rowSpacing), width: size.width, height: size.height)
            // The rows fade out towards the bottom: a list is coming, not a wall.
            card.opacity = Float(max(0.25, 1 - 0.35 * row))
        }
        CATransaction.commit()
    }
}

// MARK: - Empty and error messages

/// A grid with nothing to show: why, and Retry when asking again can help.
final class GridMessageView: UIView {

    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    let retryButton: UIButton
    private var onRetry: (() -> Void)?
    /// Down from the tab bar or from Sort / Genre reaches Retry, which is
    /// in the middle of the screen, under none of them.
    private let focusGuide = UIFocusGuide()

    init(title: String, body: String?, retry: (() -> Void)? = nil) {
        var configuration = UIButton.Configuration.gray()
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 40, bottom: 14, trailing: 40)
        configuration.attributedTitle = AttributedString("Try Again".localized, attributes: AttributeContainer([.font: GridStyle.controlFont]))
        retryButton = UIButton(configuration: configuration)
        onRetry = retry
        super.init(frame: .zero)

        titleLabel.text = title
        titleLabel.accessibilityIdentifier = "Grid.Message"
        titleLabel.font = GridStyle.messageTitleFont
        titleLabel.textColor = GridStyle.primaryText
        bodyLabel.text = body
        bodyLabel.font = GridStyle.messageBodyFont
        bodyLabel.textColor = GridStyle.secondaryText
        bodyLabel.isHidden = (body ?? "").isEmpty
        for label in [titleLabel, bodyLabel] {
            label.numberOfLines = 0
            label.textAlignment = .center
        }
        retryButton.isHidden = retry == nil
        retryButton.accessibilityIdentifier = "Grid.Retry"
        retryButton.addTarget(self, action: #selector(retryTapped), for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [titleLabel, bodyLabel, retryButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 18
        stack.setCustomSpacing(40, after: bodyLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 1100),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: GridStyle.sideInset),
        ])

        if retry != nil {
            addLayoutGuide(focusGuide)
            focusGuide.preferredFocusEnvironments = [retryButton]
            NSLayoutConstraint.activate([
                focusGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
                focusGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
                // Below the header's line.
                focusGuide.topAnchor.constraint(equalTo: topAnchor, constant: GridStyle.headerHeight + GridStyle.sectionTop),
                focusGuide.bottomAnchor.constraint(equalTo: stack.topAnchor),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func retryTapped() {
        onRetry?()
    }
}

// MARK: - Footer: the next page

/// Below the last row: a discreet activity indicator while the next page
/// loads, or — when it could not be loaded — a line saying so and Retry.
/// The titles above stay as they are.
final class GridFooterView: UICollectionReusableView {

    static let reuseIdentifier = "gridFooter"

    enum State: Equatable {
        case hidden
        case loading
        case failed(String)
        /// What a list shown in part is missing (`CollectionViewController
        /// .partialFailure`): one quiet line on the rows' left edge, Try
        /// Again right after it.
        case notice(String)

        var height: CGFloat {
            switch self {
            case .hidden: return 0
            case .loading: return 110
            case .failed: return 170
            case .notice: return 110
            }
        }
    }

    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()
    private let retryButton: UIButton
    private var centred: [NSLayoutConstraint] = []
    private var leading: [NSLayoutConstraint] = []
    /// Down from any column of the last row reaches Retry.
    private let focusGuide = UIFocusGuide()
    var onRetry: (() -> Void)?

    override init(frame: CGRect) {
        retryButton = UIButton(configuration: GridFooterView.grayButton)
        super.init(frame: frame)

        spinner.color = GridStyle.tertiaryText
        spinner.hidesWhenStopped = true
        label.font = GridStyle.messageBodyFont
        label.textColor = GridStyle.secondaryText
        retryButton.accessibilityIdentifier = "Grid.RetryMore"
        retryButton.addTarget(self, action: #selector(retryTapped), for: .primaryActionTriggered)

        let row = UIStackView(arrangedSubviews: [label, retryButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 36
        for view in [spinner, row] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        addLayoutGuide(focusGuide)
        focusGuide.preferredFocusEnvironments = [retryButton]
        centred = [
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: GridStyle.sideInset),
        ]
        leading = [
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: GridStyle.sideInset),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -GridStyle.sideInset),
        ]
        NSLayoutConstraint.activate(centred + [
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 30),
            focusGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            focusGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
            focusGuide.topAnchor.constraint(equalTo: topAnchor),
            focusGuide.heightAnchor.constraint(equalToConstant: 20),
        ])
        show(.hidden)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(_ state: State) {
        switch state {
        case .hidden:
            spinner.stopAnimating()
            label.superview?.isHidden = true
            focusGuide.isEnabled = false
        case .loading:
            spinner.startAnimating()
            label.superview?.isHidden = true
            focusGuide.isEnabled = false
        case .failed(let message):
            spinner.stopAnimating()
            showLine(message, notice: false)
        case .notice(let message):
            spinner.stopAnimating()
            showLine(message, notice: true)
        }
    }

    /// The line and Try Again: centred under a list whose next page failed;
    /// a quiet note on the rows' left edge under a list shown in part, with
    /// the system's glass button.
    private func showLine(_ message: String, notice: Bool) {
        label.text = message
        label.font = notice ? GridFooterView.noticeFont : GridStyle.messageBodyFont
        label.textColor = notice ? GridStyle.tertiaryText : GridStyle.secondaryText
        (label.superview as? UIStackView)?.spacing = notice ? 24 : 36
        NSLayoutConstraint.deactivate(notice ? centred : leading)
        NSLayoutConstraint.activate(notice ? leading : centred)
        retryButton.configuration = notice ? GridFooterView.glassButton : GridFooterView.grayButton
        retryButton.accessibilityIdentifier = notice ? "Grid.RetryNotice" : "Grid.RetryMore"
        label.accessibilityIdentifier = notice ? "Grid.Notice" : nil
        label.superview?.isHidden = false
        focusGuide.isEnabled = true
    }

    private static let noticeFont = UIFont.systemFont(ofSize: 25, weight: .medium)

    private static var grayButton: UIButton.Configuration {
        var configuration = UIButton.Configuration.gray()
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 34, bottom: 12, trailing: 34)
        configuration.attributedTitle = AttributedString("Try Again".localized, attributes: AttributeContainer([.font: GridStyle.controlFont]))
        return configuration
    }

    /// The Glass detail page's Try Again (`glassActionStyle()`), in UIKit.
    private static var glassButton: UIButton.Configuration {
        var configuration: UIButton.Configuration
        if #available(tvOS 26.0, *) {
            configuration = .glass()
        } else {
            configuration = .gray()
            configuration.cornerStyle = .capsule
        }
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 30, bottom: 12, trailing: 30)
        configuration.attributedTitle = AttributedString("Try Again".localized, attributes: AttributeContainer([.font: GridStyle.controlFont]))
        return configuration
    }

    @objc private func retryTapped() {
        onRetry?()
    }
}
