//
//  SubtitleResultsViewController.swift
//  Rivulet
//
//  "Search Subtitles…" results as a full page, one table for the detail page
//  and the player alike: a row per result, its release read into columns
//  (`ReleaseParser`) and scored against the file (`SubtitleMatch`). Filters
//  on top (source, language, type, other episodes), sortable column headers
//  (Match %, Match, Downloads, Rating), and a row's Select downloads it.
//

import UIKit

/// What the table shows, apart from the view: testable without one.
struct SubtitleTableState {
    var source: SubtitleResultFilter = .all
    /// nil: every language.
    var language: String?
    var kind: SubtitleKind?
    /// nil: either; true: SDH only; false: no SDH.
    var sdh: Bool?
    var showsOtherEpisodes = false
    var sort: SubtitleSort = .percent

    /// For an episode, a result for another episode (or season) is hidden
    /// until "Show Other Episodes"; a pack of its season stays.
    static func isOtherEpisode(_ candidate: SubtitleCandidate, file: SubtitleMatch.FileFacts?) -> Bool {
        guard let file else { return false }
        return SubtitleMatch.isOtherEpisode(candidate.info, season: candidate.season, episode: candidate.episode,
                                            file: file)
    }

    func rows(_ candidates: [SubtitleCandidate], file: SubtitleMatch.FileFacts?) -> [SubtitleCandidate] {
        let kept = candidates.filter { c in
            source.matches(c)
                && (language == nil || SubtitleTableState.languageKey(c) == language)
                && (kind == nil || c.kind == kind)
                && (sdh == nil || c.isSDH == sdh)
                && (showsOtherEpisodes || !Self.isOtherEpisode(c, file: file))
        }
        return SubtitleSort.sorted(kept, by: sort)
    }

    static func languageKey(_ candidate: SubtitleCandidate) -> String {
        guard let code = candidate.language, !code.isEmpty else { return "" }
        return Locale.LanguageCode(code).identifier(.alpha2) ?? code.lowercased()
    }
}

/// The table's columns, left to right, and where each one sits in a row.
enum SubtitleColumn: CaseIterable {
    case release, episode, language, type, sdh, source, downloads, rating, match, percent

    var title: String {
        switch self {
        case .release: "Release"
        case .episode: "Episode"
        case .language: "Language"
        case .type: "Type"
        case .sdh: "SDH"
        case .source: "Source"
        case .downloads: "Downloads"
        case .rating: "Rating"
        case .match: "Match"
        case .percent: "Match %"
        }
    }

    var sort: SubtitleSort? {
        switch self {
        case .percent: .percent
        case .match: .match
        case .downloads: .downloads
        case .rating: .rating
        default: nil
        }
    }

    /// Fixed widths; Release takes what is left.
    private var width: CGFloat {
        switch self {
        case .release: 0
        case .episode: 150
        case .language: 150
        case .type: 175
        case .sdh: 90
        case .source: 180
        case .downloads: 135
        case .rating: 95
        case .match: 135
        case .percent: 110
        }
    }

    static let gap: CGFloat = 14
    static let rowPadding: CGFloat = 22

    static func columns(isEpisode: Bool) -> [SubtitleColumn] {
        allCases.filter { isEpisode || $0 != .episode }
    }

    /// Each column's x and width inside a row `width` wide.
    static func frames(width: CGFloat, columns: [SubtitleColumn]) -> [SubtitleColumn: (x: CGFloat, width: CGFloat)] {
        let fixed = columns.reduce(0) { $0 + $1.width }
        let release = max(160, width - rowPadding * 2 - fixed - gap * CGFloat(columns.count - 1))
        var x = rowPadding
        var frames: [SubtitleColumn: (x: CGFloat, width: CGFloat)] = [:]
        for column in columns {
            let w = column == .release ? release : column.width
            frames[column] = (x, w)
            x += w + gap
        }
        return frames
    }
}

final class SubtitleResultsViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    private let results: SubtitleSearchResults
    private let heading: String
    /// Downloads and selects a result: nil when done, else why it failed.
    private let pick: (SubtitleCandidate) async -> String?
    var onDismiss: (() -> Void)?

    private var state = SubtitleTableState()
    private var rows: [SubtitleCandidate] = []
    private var busyID: String?
    private let columns: [SubtitleColumn]

    private static let margin: CGFloat = 80

    private let statusLabel = UILabel()
    private let filterBar = UIStackView()
    private let headerRow = UIView()
    private var headerButtons: [SubtitleColumn: MusicPillButton] = [:]
    /// The pills are Auto Layout views: each column moves its pill by this.
    private var headerLeading: [SubtitleColumn: NSLayoutConstraint] = [:]
    private var sourceButtons: [(filter: SubtitleResultFilter, button: MusicPillButton)] = []
    private var languageButton: MusicPillButton?
    private var typeButton: MusicPillButton?
    private var episodesButton: MusicPillButton?
    private var collectionView: UICollectionView!
    private let emptyLabel = UILabel()

    init(results: SubtitleSearchResults, heading: String,
         pick: @escaping (SubtitleCandidate) async -> String?) {
        self.results = results
        self.heading = heading
        self.pick = pick
        self.columns = SubtitleColumn.columns(isEpisode: results.file?.isEpisode == true)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        blur.frame = view.bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(blur)
        let dim = UIView(frame: view.bounds)
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(dim)

        let titleLabel = UILabel()
        titleLabel.text = "Search Results"
        titleLabel.font = .systemFont(ofSize: 52, weight: .bold)
        titleLabel.textColor = .white
        let subtitleLabel = UILabel()
        subtitleLabel.text = [heading, results.fileName].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: "  ·  ")
        subtitleLabel.font = .systemFont(ofSize: 26, weight: .regular)
        subtitleLabel.textColor = UIColor(white: 1, alpha: 0.6)
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .systemFont(ofSize: 26, weight: .medium)
        statusLabel.numberOfLines = 2

        filterBar.axis = .horizontal
        filterBar.spacing = 18
        filterBar.alignment = .center
        buildFilters()
        buildHeader()

        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 6
        layout.sectionInset = UIEdgeInsets(top: 12, left: 0, bottom: 60, right: 0)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.clipsToBounds = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(SubtitleResultCell.self, forCellWithReuseIdentifier: SubtitleResultCell.reuseID)

        emptyLabel.font = .systemFont(ofSize: 30, weight: .medium)
        emptyLabel.textColor = UIColor(white: 1, alpha: 0.6)
        emptyLabel.textAlignment = .center

        let top = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, statusLabel])
        top.axis = .vertical
        top.spacing = 6
        for v in [top, filterBar, headerRow, collectionView!, emptyLabel] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        let m = Self.margin
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: view.topAnchor, constant: 60),
            top.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: m),
            top.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -m),
            filterBar.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 26),
            filterBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: m),
            filterBar.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -m),
            filterBar.heightAnchor.constraint(equalToConstant: 70),
            headerRow.topAnchor.constraint(equalTo: filterBar.bottomAnchor, constant: 22),
            headerRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: m),
            headerRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -m),
            headerRow.heightAnchor.constraint(equalToConstant: 58),
            collectionView.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 4),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: m),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -m),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 60),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
        showStatus(nil)
        reload()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutHeader()
        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout,
           layout.itemSize.width != collectionView.bounds.width, collectionView.bounds.width > 0 {
            layout.itemSize = CGSize(width: collectionView.bounds.width, height: 76)
            layout.invalidateLayout()
        }
    }

    // MARK: Filters

    private func buildFilters() {
        let candidates = results.candidates
        for tab in SubtitleResultFilter.tabs(for: candidates, searched: results.searched) {
            let button = MusicChrome.pill(title: tab.title, symbol: nil)
            button.addAction(UIAction { [weak self] _ in
                self?.state.source = tab.filter
                self?.reload()
            }, for: .primaryActionTriggered)
            sourceButtons.append((tab.filter, button))
            filterBar.addArrangedSubview(button)
        }
        let spacer = UIView()
        spacer.widthAnchor.constraint(equalToConstant: 22).isActive = true
        filterBar.addArrangedSubview(spacer)

        let languages = Set(candidates.map(SubtitleTableState.languageKey))
        if languages.count > 1 {
            let button = MusicChrome.pill(title: "Language: All", symbol: "chevron.down")
            button.configuration?.imagePlacement = .trailing
            button.showsMenuAsPrimaryAction = true
            languageButton = button
            filterBar.addArrangedSubview(button)
        }
        let kinds = Set(candidates.map(\.kind))
        if kinds.count > 1 || Set(candidates.map(\.isSDH)).count > 1 {
            let button = MusicChrome.pill(title: "Type: All", symbol: "chevron.down")
            button.configuration?.imagePlacement = .trailing
            button.showsMenuAsPrimaryAction = true
            typeButton = button
            filterBar.addArrangedSubview(button)
        }
        let hidden = candidates.filter { SubtitleTableState.isOtherEpisode($0, file: results.file) }.count
        if hidden > 0 {
            let button = MusicChrome.pill(title: "Other Episodes (\(hidden))", symbol: "square")
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.state.showsOtherEpisodes.toggle()
                self.reload()
            }, for: .primaryActionTriggered)
            episodesButton = button
            filterBar.addArrangedSubview(button)
        }
        for case let button as UIButton in filterBar.arrangedSubviews {
            button.configuration?.titleLineBreakMode = .byTruncatingTail
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
    }

    private func refreshFilters() {
        for (filter, button) in sourceButtons { button.isOn = filter == state.source }
        let candidates = results.candidates
        if let button = languageButton {
            let keys = Set(candidates.map(SubtitleTableState.languageKey)).sorted {
                Self.languageName($0).localizedStandardCompare(Self.languageName($1)) == .orderedAscending
            }
            let all = UIAction(title: "All Languages", state: state.language == nil ? .on : .off) { [weak self] _ in
                self?.state.language = nil
                self?.reload()
            }
            button.menu = UIMenu(children: [all] + keys.map { key in
                let count = candidates.count { SubtitleTableState.languageKey($0) == key }
                return UIAction(title: "\(Self.languageName(key)) (\(count))",
                                state: state.language == key ? .on : .off) { [weak self] _ in
                    self?.state.language = key
                    self?.reload()
                }
            })
            setTitle(button, "Language: " + (state.language.map(Self.languageName) ?? "All"))
            button.isOn = state.language != nil
        }
        if let button = typeButton {
            let isAnime = results.isAnime
            let kinds = SubtitleKind.allCases.filter { kind in candidates.contains { $0.kind == kind } }
            let all = UIAction(title: "All Types", state: state.kind == nil && state.sdh == nil ? .on : .off) { [weak self] _ in
                self?.state.kind = nil
                self?.state.sdh = nil
                self?.reload()
            }
            let types: [UIMenuElement] = kinds.count > 1 ? kinds.map { kind in
                let count = candidates.count { $0.kind == kind }
                return UIAction(title: "\(kind.label(isAnime: isAnime)) (\(count))",
                                state: state.kind == kind ? .on : .off) { [weak self] _ in
                    self?.state.kind = self?.state.kind == kind ? nil : kind
                    self?.reload()
                }
            } : []
            // SDH crosses the types (a forced or dub track can be SDH), so it is its own choice.
            let sdhChoices: [UIMenuElement] = Set(candidates.map(\.isSDH)).count > 1 ? [true, false].map { value in
                let count = candidates.count { $0.isSDH == value }
                return UIAction(title: "\(value ? "SDH" : "Not SDH") (\(count))",
                                state: state.sdh == value ? .on : .off) { [weak self] _ in
                    self?.state.sdh = self?.state.sdh == value ? nil : value
                    self?.reload()
                }
            } : []
            button.menu = UIMenu(children: [UIMenu(options: .displayInline, children: [all] + types),
                                            UIMenu(options: .displayInline, children: sdhChoices)])
            let parts = [state.kind?.label(isAnime: isAnime), state.sdh.map { $0 ? "SDH" : "Not SDH" }].compactMap { $0 }
            setTitle(button, "Type: " + (parts.isEmpty ? "All" : parts.joined(separator: ", ")))
            button.isOn = state.kind != nil || state.sdh != nil
        }
        if let button = episodesButton {
            button.configuration?.image = UIImage(systemName: state.showsOtherEpisodes ? "checkmark.square.fill" : "square")
            button.isOn = state.showsOtherEpisodes
        }
        for (column, button) in headerButtons {
            let sorted = column.sort == state.sort
            button.configuration?.image = sorted ? UIImage(systemName: "chevron.down") : nil
            button.isOn = sorted
        }
    }

    private func setTitle(_ button: MusicPillButton, _ title: String) {
        guard button.configuration?.title != title else { return }
        button.configuration?.title = title
    }

    private static func languageName(_ key: String) -> String {
        key.isEmpty ? "Unknown" : TrackLabels.languageName(key) ?? key.uppercased()
    }

    // MARK: Header

    private func buildHeader() {
        for column in columns {
            if column.sort != nil {
                let button = MusicChrome.pill(title: column.title, symbol: nil, height: 54)
                button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
                button.configuration?.imagePlacement = .trailing
                button.configuration?.imagePadding = 6
                button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
                    var a = a
                    a.font = .systemFont(ofSize: 23, weight: .semibold)
                    return a
                }
                button.configuration?.preferredSymbolConfigurationForImage =
                    UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)
                button.focusOutset = 2
                button.addAction(UIAction { [weak self] _ in
                    guard let self, let sort = column.sort else { return }
                    self.state.sort = sort
                    self.reload()
                }, for: .primaryActionTriggered)
                headerButtons[column] = button
                headerRow.addSubview(button)
                button.translatesAutoresizingMaskIntoConstraints = false
                let leading = button.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor)
                headerLeading[column] = leading
                NSLayoutConstraint.activate([leading, button.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor)])
            } else {
                let label = UILabel()
                label.text = column.title
                label.font = .systemFont(ofSize: 23, weight: .semibold)
                label.textColor = UIColor(white: 1, alpha: 0.55)
                label.tag = SubtitleColumn.allCases.firstIndex(of: column)! + 1
                headerRow.addSubview(label)
            }
        }
    }

    private func layoutHeader() {
        let frames = SubtitleColumn.frames(width: headerRow.bounds.width, columns: columns)
        let height = headerRow.bounds.height
        for column in columns {
            guard let f = frames[column] else { continue }
            if let leading = headerLeading[column] {
                // The capsule sits a little outside its column so its title lines up with the cells'.
                if leading.constant != f.x - 14 { leading.constant = f.x - 14 }
            } else if let label = headerRow.viewWithTag(SubtitleColumn.allCases.firstIndex(of: column)! + 1) {
                label.frame = CGRect(x: f.x, y: 0, width: f.width, height: height)
            }
        }
    }

    // MARK: Rows

    private func reload() {
        rows = state.rows(results.candidates, file: results.file)
        refreshFilters()
        collectionView.reloadData()
        emptyLabel.isHidden = !rows.isEmpty
        emptyLabel.text = results.candidates.isEmpty ? "No Subtitles Found" : "No Results Match These Filters"
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: SubtitleResultCell.reuseID, for: indexPath)
        if let cell = cell as? SubtitleResultCell {
            let row = rows[indexPath.item]
            cell.configure(row, columns: columns, isAnime: results.isAnime, isBusy: row.id == busyID)
        }
        return cell
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        rows.isEmpty ? nil : IndexPath(item: 0, section: 0)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // Something here always takes focus: the first row, else the All tab.
        if !rows.isEmpty { return [collectionView] }
        return [sourceButtons.first?.button].compactMap { $0 }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard busyID == nil, rows.indices.contains(indexPath.item) else { return }
        let row = rows[indexPath.item]
        busyID = row.id
        showStatus(nil)
        reconfigure(row.id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let failure = await self.pick(row)
            self.busyID = nil
            guard let failure else {
                self.close()
                return
            }
            // The page stays, focus on the row that failed; Back closes it.
            self.reconfigure(row.id)
            self.showStatus(failure)
        }
    }

    private func reconfigure(_ id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        if let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? SubtitleResultCell {
            cell.configure(rows[index], columns: columns, isAnime: results.isAnime, isBusy: rows[index].id == busyID)
        }
    }

    /// A failure in orange, else the sources that failed to answer.
    private func showStatus(_ failure: String?) {
        if let failure {
            statusLabel.text = failure
            statusLabel.textColor = .systemOrange
        } else {
            statusLabel.text = results.notices.joined(separator: "  ·  ")
            statusLabel.textColor = UIColor(white: 1, alpha: 0.6)
        }
        statusLabel.isHidden = statusLabel.text?.isEmpty ?? true
    }

    // MARK: Presses

    private func close() {
        guard presentingViewController != nil, !isBeingDismissed else { return }
        dismiss(animated: true) { [onDismiss] in onDismiss?() }
    }

    // Every press stops here: a declined one would reach the presenter (the
    // player's content presses, the detail page's scrolling) behind the page.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) { close() }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {}
    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {}
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {}
}

// MARK: - Cell

final class SubtitleResultCell: UICollectionViewCell {
    static let reuseID = "SubtitleResultCell"

    private let background = UIView()
    private let releaseClip = UIView()
    private let releaseLabel = UILabel()
    private var labels: [SubtitleColumn: UILabel] = [:]
    private var columns: [SubtitleColumn] = []
    private var cleanName = ""
    private var fullName = ""
    private var isStrong = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        background.layer.cornerRadius = 16
        background.layer.cornerCurve = .continuous
        contentView.addSubview(background)
        releaseClip.clipsToBounds = true
        releaseClip.addSubview(releaseLabel)
        contentView.addSubview(releaseClip)
        releaseLabel.font = .systemFont(ofSize: 28, weight: .medium)
        for column in SubtitleColumn.allCases where column != .release {
            let label = UILabel()
            label.font = .systemFont(ofSize: 26, weight: column == .percent ? .bold : .regular)
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.8
            labels[column] = label
            contentView.addSubview(label)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ c: SubtitleCandidate, columns: [SubtitleColumn], isAnime: Bool, isBusy: Bool) {
        self.columns = columns
        let info = c.info
        fullName = c.release.isEmpty ? (TrackLabels.languageName(c.language) ?? "Subtitles") : c.release
        // Shortened only when the group is known: "AMZN WEB-DL" alone says less than the name.
        cleanName = info.group != nil ? (info.cleanName ?? fullName) : fullName
        isStrong = c.matchPercent >= 90
        labels[.episode]?.text = Self.episode(c, info)
        labels[.language]?.text = TrackLabels.languageName(c.language) ?? "—"
        labels[.type]?.text = c.kind.label(isAnime: isAnime)
        labels[.sdh]?.text = c.isSDH ? "SDH" : "—"
        labels[.source]?.text = c.origin == .plexSearch ? "Plex" : c.origin.label
        labels[.downloads]?.text = c.downloads.map { $0.formatted(.number) } ?? "—"
        // OpenSubtitles sends 0 for unrated.
        labels[.rating]?.text = c.rating.flatMap { $0 > 0 ? String(format: "%.1f", $0) : nil } ?? "—"
        labels[.match]?.text = isBusy ? "Downloading…" : c.matchKind.label
        labels[.percent]?.text = "\(c.matchPercent)%"
        for (column, label) in labels { label.isHidden = !columns.contains(column) }
        applyFocus(isFocused)
        setNeedsLayout()
    }

    static func episode(_ c: SubtitleCandidate, _ info: ReleaseInfo) -> String {
        let season = c.season ?? info.season, episode = c.episode ?? info.episode
        if info.isSeasonPack, c.episode == nil { return "Season pack" }
        switch (season, episode) {
        case let (s?, e?): return String(format: "S%02dE%02d", s, e)
        case let (nil, e?): return String(format: "E%02d", e)
        case let (s?, nil): return String(format: "S%02d", s)
        default: return "—"
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        background.frame = contentView.bounds
        let frames = SubtitleColumn.frames(width: contentView.bounds.width, columns: columns)
        let h = contentView.bounds.height
        if let f = frames[.release] {
            releaseClip.frame = CGRect(x: f.x, y: 0, width: f.width, height: h)
            layoutRelease()
        }
        for (column, label) in labels {
            guard let f = frames[column] else { continue }
            label.frame = CGRect(x: f.x, y: 0, width: f.width, height: h)
        }
    }

    private func layoutRelease() {
        let width = max(releaseClip.bounds.width, releaseLabel.intrinsicContentSize.width)
        releaseLabel.frame = CGRect(x: 0, y: 0, width: isFocused ? width : releaseClip.bounds.width,
                                    height: releaseClip.bounds.height)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations { self.applyFocus(focused) }
    }

    /// Focused: a white row with dark text and the full release name scrolling
    /// when it is longer than its column. At rest: the cleaned name, and a
    /// green tint for a 90%+ match.
    private func applyFocus(_ focused: Bool) {
        background.backgroundColor = focused ? .white
            : isStrong ? UIColor.systemGreen.withAlphaComponent(0.18) : UIColor(white: 1, alpha: 0.06)
        transform = focused ? CGAffineTransform(scaleX: 1.01, y: 1.01) : .identity
        let text: UIColor = focused ? UIColor(white: 0.08, alpha: 1) : .white
        releaseLabel.textColor = text
        for (column, label) in labels {
            label.textColor = column == .percent && isStrong
                ? (focused ? UIColor(red: 0, green: 0.45, blue: 0.15, alpha: 1) : .systemGreen)
                : focused ? UIColor(white: 0.15, alpha: 1) : UIColor(white: 1, alpha: 0.8)
        }
        releaseLabel.text = focused ? fullName : cleanName
        releaseLabel.lineBreakMode = focused ? .byClipping : .byTruncatingTail
        layoutRelease()
        marquee(focused)
    }

    private func marquee(_ on: Bool) {
        releaseLabel.layer.removeAnimation(forKey: "marquee")
        let overflow = releaseLabel.frame.width - releaseClip.bounds.width
        guard on, overflow > 1 else { return }
        let pause = 1.2, travel = Double(overflow) / 70
        let total = pause * 2 + travel
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, 0, -overflow, -overflow]
        animation.keyTimes = [0, NSNumber(value: pause / total), NSNumber(value: (pause + travel) / total), 1]
        animation.duration = total
        animation.autoreverses = true
        animation.repeatCount = .infinity
        releaseLabel.layer.add(animation, forKey: "marquee")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        releaseLabel.layer.removeAnimation(forKey: "marquee")
    }
}
