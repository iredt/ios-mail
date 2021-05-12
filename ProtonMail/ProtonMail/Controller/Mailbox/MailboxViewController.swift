//
//  MailboxViewController.swift
//  ProtonMail - Created on 8/16/15.
//
//
//  Copyright (c) 2019 Proton Technologies AG
//
//  This file is part of ProtonMail.
//
//  ProtonMail is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  ProtonMail is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with ProtonMail.  If not, see <https://www.gnu.org/licenses/>.


import UIKit
import CoreData
import PMCommon
import PMUIFoundations
import SkeletonView
import SwipyCell

class MailboxViewController: ProtonMailViewController, ViewModelProtocol, CoordinatedNew, ComposeSaveHintProtocol {
    typealias viewModelType = MailboxViewModel
    typealias coordinatorType = MailboxCoordinator

    private(set) var viewModel: MailboxViewModel!
    private var coordinator: MailboxCoordinator?
    
    func getCoordinator() -> CoordinatorNew? {
        return self.coordinator
    }
    
    func set(coordinator: MailboxCoordinator) {
        self.coordinator = coordinator
    }
    
    func set(viewModel: MailboxViewModel) {
        self.viewModel = viewModel
    }

    lazy var replacingEmails: [Email] = { [unowned self] in
        viewModel.allEmails()
    }()

    var listEditing: Bool = false
    
    // MARK: - View Outlets
    @IBOutlet weak var tableView: UITableView!
    
    // MARK: - Private constants
    private let kMailboxCellHeight: CGFloat           = 62.0 // change it to auto height
    private let kMailboxRateReviewCellHeight: CGFloat = 125.0
    private let kLongPressDuration: CFTimeInterval    = 0.60 // seconds
    private let kMoreOptionsViewHeight: CGFloat       = 123.0
    
    private let kUndoHidePosition: CGFloat = -100.0
    private let kUndoShowPosition: CGFloat = 44
    
    /// The undo related UI. //TODO:: should move to a custom view to handle it.
    @IBOutlet weak var undoView: UIView!
    @IBOutlet weak var undoLabel: UILabel!
    @IBOutlet weak var undoButton: UIButton!
    @IBOutlet weak var undoButtonWidth: NSLayoutConstraint!
    @IBOutlet weak var undoBottomDistance: NSLayoutConstraint!
    
    // MARK: TopActions
    @IBOutlet weak var topActionsView: UIView!
    @IBOutlet weak var updateTimeLabel: UILabel!
    @IBOutlet weak var unreadFilterButton: UIButton!
    @IBOutlet weak var unreadFilterButtonWidth: NSLayoutConstraint!
    
    // MARK: TopMessage
    private weak var topMessageView: BannerView?
    
    // MARK: MailActionBar
    private var mailActionBar: PMActionBar?
    
    // MARK: - Private attributes
    private var timer : Timer!
    private var timerAutoDismiss : Timer?

    private var bannerContainer: UIView?
    private var bannerShowConstrain: NSLayoutConstraint?
    private var isInternetBannerPresented = false
    private var isHidingBanner = false
    
    private var fetchingNewer : Bool = false
    private var fetchingOlder : Bool = false
    private var indexPathForSelectedRow : IndexPath!
    
    private var undoMessage : UndoMessage?
    
    private var isShowUndo : Bool = false
    private var isCheckingHuman: Bool = false
    
    private var fetchingMessage : Bool! = false
    private var fetchingStopped : Bool! = true
    private var needToShowNewMessage : Bool = false
    private var newMessageCount = 0
    
    // MAKR : - Private views
    private var refreshControl: UIRefreshControl!
    private var navigationTitleLabel = UILabel()
    
    // MARK: - Right bar buttons
    private var composeBarButtonItem: UIBarButtonItem!
    private var searchBarButtonItem: UIBarButtonItem!
    private var cancelBarButtonItem: UIBarButtonItem!
    
    // MARK: - Left bar button
    private var menuBarButtonItem: UIBarButtonItem!
    
    // MARK: - No result image and label
    @IBOutlet weak var noResultImage: UIImageView!
    @IBOutlet weak var noResultMainLabel: UILabel!
    @IBOutlet weak var noResultSecondaryLabel: UILabel!
    @IBOutlet weak var noResultFooterLabel: UILabel!
    
    // MARK: action sheet
    private var actionSheet: PMActionSheet?
    
    private var lastNetworkStatus : NetworkStatus? = nil
    
    private var shouldAnimateSkeletonLoading = false
    private var isShowingUnreadMessageOnly: Bool {
        return self.unreadFilterButton.isSelected
    }
    
    ///This variable is to determine should we show the skeleton view or not
    private var isFirstQueryOfThisEmptyIndex = true

    private let messageCellPresenter = NewMailboxMessageCellPresenter()
    private let mailListActionSheetPresenter = MailListActionSheetPresenter()
    private lazy var moveToActionSheetPresenter = MoveToActionSheetPresenter()
    private lazy var labelAsActionSheetPresenter = LabelAsActionSheetPresenter()

    func inactiveViewModel() {
        guard self.viewModel != nil else {
            return
        }
        self.viewModel.resetFetchedController()
    }
    
    deinit {
        self.viewModel?.resetFetchedController()
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc func doEnterForeground() {
        if viewModel.reloadTable() {
            resetTableView()
        }
        self.updateLastUpdateTimeLabel()
        self.updateUnreadButton()
    }
    
    func resetTableView() {
        self.viewModel.resetFetchedController()
        self.viewModel.setupFetchController(self)
        self.tableView.reloadData()
    }
    
    // MARK: - UIViewController Lifecycle
    
    class func instance() -> MailboxViewController {
        let board = UIStoryboard.Storyboard.inbox.storyboard
        let vc = board.instantiateViewController(withIdentifier: "MailboxViewController") as! MailboxViewController
        let _ = UINavigationController(rootViewController: vc)
        return vc
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        assert(self.viewModel != nil)
        assert(self.coordinator != nil)

        self.viewModel.setupFetchController(self,
                                            isUnread: viewModel.isCurrentUserSelectedUnreadFilterInInbox)
        if viewModel.isCurrentUserSelectedUnreadFilterInInbox && viewModel.countOfFetchedObjects == 0 {
            self.viewModel.fetchMessages(time: 0, forceClean: false, isUnread: true, completion: nil)
        }
        
        self.undoButton.setTitle(LocalString._messages_undo_action, for: .normal)
        self.setNavigationTitleText(viewModel.localizedNavigationTitle)
        
        SkeletonAppearance.default.renderSingleLineAsView = true
        
        self.tableView.separatorColor = UIColorManager.InteractionWeak
        self.tableView.register(NewMailboxMessageCell.self, forCellReuseIdentifier: NewMailboxMessageCell.defaultID())
        self.tableView.RegisterCell(MailBoxSkeletonLoadingCell.Constant.identifier)
        
        self.addSubViews()

        self.updateNavigationController(listEditing)
        
        if !userCachedStatus.isTourOk() {
            userCachedStatus.resetTourValue()
            self.coordinator?.go(to: .onboarding)
        }
        
        self.undoBottomDistance.constant = self.kUndoHidePosition
        self.undoButton.isHidden = true
        self.undoView.isHidden = true
        
        //Setup top actions
        self.topActionsView.backgroundColor = UIColorManager.BackgroundNorm
        self.updateTimeLabel.textColor = UIColorManager.TextHint
        
        configureUnreadFilterButton()
        
        self.updateUnreadButton()
        self.updateLastUpdateTimeLabel()
        
        self.viewModel.cleanReviewItems()
        generateAccessibilityIdentifiers()
        configureBannerContainer()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.hideTopMessage()
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reachabilityChanged(_:)),
                                               name: NSNotification.Name.reachabilityChanged,
                                               object: nil)
        if #available(iOS 13.0, *) {
            NotificationCenter.default.addObserver(self,
                                                   selector:#selector(doEnterForeground),
                                                   name:  UIWindowScene.willEnterForegroundNotification,
                                                   object: nil)
        } else {
            NotificationCenter.default.addObserver(self,
                                                    selector:#selector(doEnterForeground),
                                                    name: UIApplication.willEnterForegroundNotification,
                                                    object: nil)
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.hideTopMessage()
        NotificationCenter.default.removeObserver(self)
//        self.stopAutoFetch()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        if #available(iOS 13.0, *) {
            self.view.window?.windowScene?.title = self.title ?? LocalString._locations_inbox_title
        }
        
        guard let users = self.viewModel.users, users.count > 0 else {
            return
        }
        
        self.viewModel.processCachedPush()
        self.viewModel.checkStorageIsCloseLimit()

        self.updateInterface(reachability: sharedInternetReachability)
        
        let selectedItem: IndexPath? = self.tableView.indexPathForSelectedRow as IndexPath?
        if let selectedItem = selectedItem {
            if self.viewModel.isDrafts() {
                // updated draft should either be deleted or moved to top, so all the rows in between should be moved 1 position down
                let rowsToMove = (0...selectedItem.row).map{ IndexPath(row: $0, section: 0) }
                self.tableView.reloadRows(at: rowsToMove, with: .top)
            } else {
                self.tableView.reloadRows(at: [selectedItem], with: .fade)
                self.tableView.deselectRow(at: selectedItem, animated: true)
            }
        }

        if timer == nil {
            self.startAutoFetch()
        }
        
        FileManager.default.cleanCachedAttsLegacy()
        
        if self.viewModel.notificationMessageID != nil {
            self.coordinator?.go(to: .details) // FIXME: - To update MG
        } else if checkHuman() {
            self.handleUpdateAlert()
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        self.tableView.zeroMargin()
    }
    
    private func addSubViews() {
        self.navigationTitleLabel.backgroundColor = UIColor.clear
        self.navigationTitleLabel.font = Fonts.h3.semiBold
        self.navigationTitleLabel.textAlignment = NSTextAlignment.center
        self.navigationTitleLabel.textColor = UIColorManager.TextNorm
        self.navigationTitleLabel.text = self.title ?? LocalString._locations_inbox_title
        self.navigationTitleLabel.sizeToFit()
        self.navigationItem.titleView = navigationTitleLabel
        
        self.refreshControl = UIRefreshControl()
        self.refreshControl.backgroundColor = .clear
        self.refreshControl.addTarget(self, action: #selector(pullDown), for: UIControl.Event.valueChanged)
        self.refreshControl.tintColor = UIColorManager.BrandNorm
        self.refreshControl.tintColorDidChange()
        
        self.view.backgroundColor = UIColorManager.BackgroundNorm

        self.tableView.addSubview(self.refreshControl)
        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.tableView.noSeparatorsBelowFooter()
        
        let longPressGestureRecognizer: UILongPressGestureRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGestureRecognizer.minimumPressDuration = kLongPressDuration
        self.tableView.addGestureRecognizer(longPressGestureRecognizer)
        
        self.menuBarButtonItem = self.navigationItem.leftBarButtonItem
        self.menuBarButtonItem.tintColor = UIColorManager.IconNorm
        
        self.noResultMainLabel.textColor = UIColorManager.TextNorm
        self.noResultMainLabel.isHidden = true
        
        self.noResultSecondaryLabel.textColor = UIColorManager.TextWeak
        self.noResultSecondaryLabel.isHidden = true
        
        self.noResultFooterLabel.textColor = UIColorManager.TextHint
        self.noResultFooterLabel.isHidden = true
        let attridutes = FontManager.CaptionHint
        self.noResultFooterLabel.attributedText = NSAttributedString(string: LocalString._mailbox_footer_no_result, attributes: attridutes)
        
        self.noResultImage.isHidden = true
    }
    
    // MARK: - Public methods
    func setNavigationTitleText(_ text: String?) {
        let animation = CATransition()
        animation.duration = 0.25
        animation.type = CATransitionType.fade
        self.navigationController?.navigationBar.layer.add(animation, forKey: "fadeText")
        if let t = text, t.count > 0 {
            self.title = t
            self.navigationTitleLabel.text = t
        } else {
            self.title = ""
            self.navigationTitleLabel.text = ""
        }
        self.navigationTitleLabel.sizeToFit()
    }
    
    func showNoEmailSelected(title: String) {
        let alert = UIAlertController(title: title, message: LocalString._message_list_no_email_selected, preferredStyle: .alert)
        alert.addOKAction()
        self.present(alert, animated: true, completion: nil)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        handleShadow(isScrolled: scrollView.contentOffset.y > 0)
    }
    
    // MARK: - Button Targets
    @IBAction func undoAction(_ sender: UIButton) {
        self.undoTheMessage()
        self.hideUndoView()
    }
    
    @objc internal func composeButtonTapped() {
        if checkHuman() {
            self.coordinator?.go(to: .composer)
        }
    }
    
    @objc internal func searchButtonTapped() {
        self.coordinator?.go(to: .search)
    }
    
    @objc internal func cancelButtonTapped() {
        self.viewModel.removeAllSelectedIDs()
        self.hideCheckOptions()
        self.updateNavigationController(false)
        if !self.timer.isValid {
            self.startAutoFetch(false)
        }
        self.hideActionBar()
        self.hideActionSheet()
    }
    
    @objc internal func handleLongPress(_ longPressGestureRecognizer: UILongPressGestureRecognizer) {
        self.showCheckOptions(longPressGestureRecognizer)
        updateNavigationController(listEditing)
        // invalidate tiemr in multi-selected mode to prevent ui refresh issue
        self.timer.invalidate()
    }
    
    @IBAction func unreadMessageFilterButtonTapped(_ sender: Any) {
        self.unreadFilterButton.isSelected.toggle()
        let isSelected = self.unreadFilterButton.isSelected
        if isSelected {
            //update the predicate in fetch controller
            self.viewModel.setupFetchController(self, isUnread: true)

            if self.viewModel.countOfFetchedObjects == 0 {
                self.viewModel.fetchMessages(time: 0, forceClean: false, isUnread: true, completion: nil)
            }
        } else {
            self.viewModel.setupFetchController(self, isUnread: false)
        }
        self.viewModel.isCurrentUserSelectedUnreadFilterInInbox = isSelected
        self.tableView.reloadData()
        self.updateUnreadButton()
        self.handleNoResultImage()
    }
    
    private func beginRefreshingManually(animated: Bool) {
        if animated {
            self.refreshControl.beginRefreshing()
        }
    }
    
    // MARK: - Private methods
    
    // MARK: Auto refresh methods
    private func startAutoFetch(_ run : Bool = true) {
        self.timer = Timer.scheduledTimer(timeInterval: self.timerInterval,
                                          target: self,
                                          selector: #selector(refreshPage),
                                          userInfo: nil,
                                          repeats: true)
        fetchingStopped = false
        if run {
            self.timer.fire()
        }
    }
    
    private func stopAutoFetch() {
        fetchingStopped = true
        if self.timer != nil {
            self.timer.invalidate()
            self.timer = nil
        }
    }
    
    @objc private func refreshPage() {
        if !fetchingStopped {
            self.getLatestMessages()
        }
    }
    
    private func checkContact() {
        self.viewModel.fetchContacts()
    }
    
    @discardableResult
    private func checkHuman() -> Bool {
        if self.viewModel.isRequiredHumanCheck && isCheckingHuman == false {
            //show human check view with warning
            isCheckingHuman = true
            self.coordinator?.go(to: .humanCheck)
            return false
        }
        return true
    }
    
    private func checkDoh(_ error : NSError) -> Bool {
        let code = error.code
        guard DoHMail.default.codeCheck(code: code) else {
            return false
        }
        self.showError(error)
        return true
        
    }
    
    private var timerInterval : TimeInterval = 30
    private var failedTimes = 30
    
    private func offlineTimerReset() {
        timerInterval = TimeInterval(arc4random_uniform(90)) + 30
        stopAutoFetch()
        startAutoFetch(false)
    }
    
    private func onlineTimerReset() {
        timerInterval = 30
        stopAutoFetch()
        startAutoFetch(false)
    }

    // MARK: cell configuration methods
    private func configure(cell inputCell: UITableViewCell?, indexPath: IndexPath) {
        guard let mailboxCell = inputCell as? NewMailboxMessageCell else {
            return
        }
        
        switch self.viewModel.viewMode {
        case .singleMessage:
            guard let message: Message = self.viewModel.item(index: indexPath) else {
                return
            }
            let viewModel = buildNewMailboxMessageViewModel(message: message)
            mailboxCell.id = message.messageID
            mailboxCell.cellDelegate = self
            messageCellPresenter.present(viewModel: viewModel, in: mailboxCell.customView)

            configureSwipeAction(mailboxCell, indexPath: indexPath, message: message)
        case .conversation:
            guard let _ = self.viewModel.itemOfConversation(index: indexPath) else {
                return
            }
        }
    }

    private func configureSwipeAction(_ cell: SwipyCell, indexPath: IndexPath, message: Message) {
        let leftToRightAction = userCachedStatus.leftToRightSwipeActionType
        let leftToRightMsgAction = viewModel.convertSwipeActionTypeToMessageSwipeAction(leftToRightAction,
                                                                                        message: message)

        if leftToRightMsgAction != .none && viewModel.isSwipeActionValid(leftToRightMsgAction, message: message) {
            let leftToRightSwipeView = makeSwipeView(messageSwipeAction: leftToRightMsgAction)
            cell.addSwipeTrigger(forState: .state(0, .left),
                                 withMode: .exit,
                                 swipeView: leftToRightSwipeView,
                                 swipeColor: leftToRightMsgAction.actionColor) { [weak self] (cell, trigger, state, mode) in
                guard let self = self else { return }
                self.handleSwipeAction(on: cell, action: leftToRightMsgAction, message: message)
            }
        }

        let rightToLeftAction = userCachedStatus.rightToLeftSwipeActionType
        let rightToLeftMsgAction = viewModel.convertSwipeActionTypeToMessageSwipeAction(rightToLeftAction, message: message)

        if rightToLeftMsgAction != .none && viewModel.isSwipeActionValid(rightToLeftMsgAction, message: message) {
            let rightToLeftSwipeView = makeSwipeView(messageSwipeAction: rightToLeftMsgAction)
            cell.addSwipeTrigger(forState: .state(0, .right),
                                 withMode: .exit,
                                 swipeView: rightToLeftSwipeView,
                                 swipeColor: rightToLeftMsgAction.actionColor) { [weak self] (cell, trigger, state, mode) in
                guard let self = self else { return }
                self.handleSwipeAction(on: cell, action: rightToLeftMsgAction, message: message)
            }
        }
    }

    private func handleSwipeAction(on cell: SwipyCell, action: MessageSwipeAction, message: Message) {
        guard let indexPathOfCell = self.tableView.indexPath(for: cell) else {
            self.tableView.reloadData()
            return
        }

        guard self.viewModel.isSwipeActionValid(action, message: message) else {
            cell.swipeToOrigin {}
            return
        }

        if !self.processSwipeActions(action,
                                     indexPath: indexPathOfCell) {
            cell.swipeToOrigin {}
        }
    }

    private func processSwipeActions(_ action: MessageSwipeAction, indexPath: IndexPath) -> Bool {
        /// UIAccessibility
        UIAccessibility.post(notification: UIAccessibility.Notification.announcement, argument: action.description)
        // TODO: handle conversation
        switch action {
        case .none:
            break
        case .labelAs:
            labelAs(indexPath)
        case .moveTo:
            moveTo(indexPath)
        case .unread:
            self.unread(indexPath)
            return false
        case .read:
            self.read(indexPath)
            return false
        case .star:
            self.star(indexPath)
            return false
        case .unstar:
            self.unstar(indexPath)
            return false
        case .trash:
            self.delete(indexPath)
            return true
        case .archive:
            self.archive(indexPath)
            return true
        case .spam:
            self.spam(indexPath)
            return true
        }
        return false
    }

    private func labelAs(_ index: IndexPath) {
        guard let message = viewModel.item(index: index) else { return }
        showLabelAsActionSheet(messages: [message])
    }

    private func moveTo(_ index: IndexPath) {
        guard let message = viewModel.item(index: index) else { return }
        let isEnableColor = viewModel.user.isEnableFolderColor
        let isInherit = viewModel.user.isInheritParentFolderColor
        showMoveToActionSheet(messages: [message],
                              isEnableColor: isEnableColor,
                              isInherit: isInherit)
    }
    
    private func archive(_ index: IndexPath) {
        let (res, undo) = self.viewModel.archive(index: index)
        switch res {
        case .showUndo:
            undoMessage = undo
            showUndoView(LocalString._messages_archived)
        case .showGeneral:
            showMessageMoved(title: LocalString._messages_has_been_moved)
        default: break
        }
    }
    
    private func delete(_ index: IndexPath) {
        let (res, undo) = self.viewModel.delete(index: index)
        switch res {
        case .showUndo:
            undoMessage = undo
            showUndoView(LocalString._locations_deleted_desc)
        case .showGeneral:
            showMessageMoved(title: LocalString._messages_has_been_deleted)
        default: break
        }
    }
    
    private func spam(_ index: IndexPath) {
        let (res, undo) = self.viewModel.spam(index: index)
        switch res {
        case .showUndo:
            undoMessage = undo
            showUndoView(LocalString._messages_spammed)
        case .showGeneral:
            showMessageMoved(title: LocalString._messages_has_been_moved)
        default: break
        }
    }
    
    private func star(_ indexPath: IndexPath) {
        guard let message = self.viewModel.item(index: indexPath) else { return }
        self.viewModel.label(msg: message, with: Message.Location.starred.rawValue)
    }

    private func unstar(_ indexPath: IndexPath) {
        guard let message = self.viewModel.item(index: indexPath) else { return }
        self.viewModel.label(msg: message, with: Message.Location.starred.rawValue, apply: false)
    }

    private func unread(_ indexPath: IndexPath) {
        guard let message = self.viewModel.item(index: indexPath) else { return }
        self.viewModel.mark(messages: [message])
    }

    private func read(_ indexPath: IndexPath) {
        guard let message = self.viewModel.item(index: indexPath) else { return }
        self.viewModel.mark(messages: [message], unread: false)
    }

    private func makeSwipeView(messageSwipeAction: MessageSwipeAction) -> UIView {
        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.spacing = 4
        stackView.alignment = .center
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let iconView = UIImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        [
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24)
        ].activate()

        stackView.addArrangedSubview(iconView)
        stackView.addArrangedSubview(label)

        var attribute = FontManager.CaptionStrong
        attribute[.foregroundColor] = UIColorManager.TextInverted
        label.attributedText = messageSwipeAction.description.apply(style: attribute)
        iconView.image = messageSwipeAction.icon
        iconView.tintColor = UIColorManager.TextInverted

        return stackView
    }

    private func undoTheMessage() { //need move into viewModel
        if let undoMsg = undoMessage {
            self.viewModel.undo(undoMsg)
            undoMessage = nil
        }
    }
    
    private func showUndoView(_ title : String) {
        undoLabel.text = String(format: LocalString._messages_with_title, title)
        self.undoBottomDistance.constant = self.kUndoShowPosition
        self.undoButton.isHidden = false
        self.undoView.isHidden = false
        self.undoButtonWidth.constant = 100.0
        self.updateViewConstraints()
        UIView.animate(withDuration: 0.25, animations: { () -> Void in
            self.view.layoutIfNeeded()
        })
        self.timerAutoDismiss?.invalidate()
        self.timerAutoDismiss = nil
        self.timerAutoDismiss = Timer.scheduledTimer(timeInterval: 3,
                                                     target: self,
                                                     selector: #selector(MailboxViewController.timerTriggered),
                                                     userInfo: nil,
                                                     repeats: false)
    }
    
    private func showMessageMoved(title : String) {
        undoLabel.text = title
        self.undoBottomDistance.constant = self.kUndoShowPosition
        self.undoButton.isHidden = false
        self.undoView.isHidden = false
        self.undoButtonWidth.constant = 0.0
        self.updateViewConstraints()
        UIView.animate(withDuration: 0.25, animations: { () -> Void in
            self.view.layoutIfNeeded()
        })
        self.timerAutoDismiss?.invalidate()
        self.timerAutoDismiss = nil
        self.timerAutoDismiss = Timer.scheduledTimer(timeInterval: 3,
                                                     target: self,
                                                     selector: #selector(MailboxViewController.timerTriggered),
                                                     userInfo: nil,
                                                     repeats: false)
    }
    
    private func hideUndoView() {
        self.timerAutoDismiss?.invalidate()
        self.timerAutoDismiss = nil
        self.undoBottomDistance.constant = self.kUndoHidePosition
        self.updateViewConstraints()
        UIView.animate(withDuration: 0.25, animations: {
            self.view.layoutIfNeeded()
        }) { _ in
            self.undoButton.isHidden = true
            self.undoView.isHidden = true
        }
    }
    
    @objc private func timerTriggered() {
        self.hideUndoView()
    }
    
    private func checkEmptyMailbox () {
        guard self.viewModel.sectionCount() > 0 else {
            return
        }
        self.pullDown()
    }
    
    private func handleRequestError(_ error : NSError) {
        PMLog.D("error: \(error)")
        guard sharedInternetReachability.currentReachabilityStatus() != .NotReachable else { return }
        guard checkDoh(error) == false else {
            return
        }
        switch error.code {
        case NSURLErrorTimedOut, APIErrorCode.HTTP504, APIErrorCode.HTTP404:
            showTimeOutErrorMessage()
        case NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost:
            showNoInternetErrorMessage()
        case APIErrorCode.API_offline:
            showOfflineErrorMessage(error)
            offlineTimerReset()
        case APIErrorCode.HTTP503, NSURLErrorBadServerResponse:
            show503ErrorMessage(error)
            offlineTimerReset()
        case APIErrorCode.forcePasswordChange:
            showErrorMessage(error)
        default:
            showTimeOutErrorMessage()
        }
    }

    @objc private func pullDown() {
        guard !tableView.isDragging else {
            return
        }

        self.getLatestMessagesRaw { (fetch) in
            if fetch {
                //temperay to fix the new messages are not loaded
                self.fetchNewMessage()
            }
        }
    }
    
    private func fetchNewMessage() {
        viewModel.fetchMessages(time: 0, forceClean: false, isUnread: self.isShowingUnreadMessageOnly) { (task, res, error) in
            self.handleNoResultImage()
        }
        
//        viewModel.fetchConversations() { task, res, error  in
//            switch result {
//            case .success(let conversationIDs):
//                let conversationID = conversationIDs.first!
//                self.viewModel.fetchConversationDetail(converstaionID: conversationID) { result in
//                    switch result {
//                    case .success(let msgIDs):
//                        print(msgIDs)
//                    case .failure(let error):
//                        print(error)
//                    }
//                }
                
//                self.viewModel.markConversationAsUnread(conversationIDs: [conversationIDs.first!], currentLabelID: "0") { (result) in
//                    switch result {
//                    case .success(let result):
//                        print(result)
//                    case .failure(let error):
//                        print(error)
//                    }
//                }
//                self.viewModel.markConversationAsRead(conversationIDs: [conversationIDs.first!]) { (result) in
//                    switch result {
//                    case .success(let result):
//                        print(result)
//                    case .failure(let error):
//                        print(error)
//                    }
//                }
//                self.viewModel.fetchConversationCount { (result) in
//                    switch result {
//                    case .success(let counts):
//                        print(counts)
//                    case .failure(let error):
//                        print(error)
//                    }
//                }
                
//                self.viewModel.labelConversations(conversationIDs: [conversationIDs.first!], labelID: Message.Location.starred.rawValue) { (result) in
//                    switch result {
//                    case .success(let result):
//                        print(result)
//                    case .failure(let error):
//                        print(error)
//                    }
//                }
                
//                self.viewModel.unlabelConversations(conversationIDs: [conversationIDs.first!], labelID: Message.Location.starred.rawValue) { (result) in
//                    switch result {
//                    case .success(let result):
//                        print(result)
//                    case .failure(let error):
//                        print(error)
//                    }
//                }
//
//                self.viewModel.deleteConversations(conversationIDs: [conversationIDs.first!], labelID: "3") { (result) in
//                    switch result {
//                    case .success(let result):
//                        print(result)
//                    case .failure(let error):
//                        print(error)
//                    }
//                }
                
//            case .failure(let error):
//                break
//            }
//        }
    }
    
    @objc private func goTroubleshoot() {
        self.coordinator?.go(to: .troubleShoot)
    }
    
    var retryCounter = 0
    @objc private func getLatestMessages() {
        self.getLatestMessagesRaw { [weak self] (_) in
            self?.updateLastUpdateTimeLabel()
            self?.deleteExpiredMessages()
        }
    }
    private func getLatestMessagesRaw(_ CompleteIsFetch: ((_ fetch: Bool) -> Void)?) {
        self.hideTopMessage()
        if !fetchingMessage {
            fetchingMessage = true
            self.beginRefreshingManually(animated: self.viewModel.rowCount(section: 0) < 1 ? true : false)
            let complete : CompletionBlock = { (task, res, error) -> Void in
                self.needToShowNewMessage = false
                self.newMessageCount = 0
                self.fetchingMessage = false
                
                if self.fetchingStopped! == true {
                    self.refreshControl?.endRefreshing()
                    return
                }
                
                if let error = error {
                    self.handleRequestError(error)
                }
                
                var loadMore: Int = 0
                if error == nil {
                    self.onlineTimerReset()
                    self.viewModel.resetNotificationMessage()
                    if let notices = res?["Notices"] as? [String] {
                        serverNotice.check(notices)
                    }
                    
                    if let more = res?["More"] as? Int {
                       loadMore = more
                    }
                    
                    if loadMore <= 0 {
                        self.viewModel.messageService.updateMessageCount() {
                            self.updateUnreadButton()
                        }
                    }
                }
                
                if loadMore > 0 {
                    if self.retryCounter >= 10 {
                        delay(1.0) {
                            self.viewModel.fetchMessages(time: 0, forceClean: false, isUnread: false) { (_, _, _) in
                                self.retry()
                                self.retryCounter += 1
                            }
                        }
                    } else {
                        self.viewModel.fetchMessages(time: 0, forceClean: false, isUnread: false) { (_, _, _) in
                            self.retry()
                            self.retryCounter += 1
                        }
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now()+0.5) {
                        if self.refreshControl.isRefreshing {
                            self.refreshControl.endRefreshing()
                        }
                    }
                    
                    self.retryCounter = 0
                    if self.fetchingStopped! == true {
                        return
                    }
                    self.handleNoResultImage()
                    let _ = self.checkHuman()
                    
                    //temperay to check message status and fetch metadata
                    self.viewModel.messageService.purgeOldMessages()
                    
                    if userCachedStatus.hasMessageFromNotification {
                        userCachedStatus.hasMessageFromNotification = false
                        self.viewModel.fetchMessages(time: 0, forceClean: false, isUnread: false, completion: nil)
                    } else {
                        if self.shouldAnimateSkeletonLoading {
                            self.shouldAnimateSkeletonLoading = false
                            self.updateTimeLabel.hideSkeleton()
                            self.unreadFilterButton.titleLabel?.hideSkeleton()
                            self.tableView.reloadData()
                        }
                        
                        self.updateLastUpdateTimeLabel()
                        CompleteIsFetch?(true)
                    }
                }
            }
            self.showRefreshController()
            
            if let updateTime = viewModel.lastUpdateTime(), updateTime.isNew == false, viewModel.isEventIDValid() {
                //fetch
                self.needToShowNewMessage = true
                viewModel.fetchEvents(time: Int(updateTime.startTime.timeIntervalSince1970),
                                      notificationMessageID: self.viewModel.notificationMessageID,
                                      completion: complete)
            } else {
                
                if isFirstQueryOfThisEmptyIndex {
                    self.shouldAnimateSkeletonLoading = true
                    self.updateTimeLabel.showAnimatedGradientSkeleton()
                    self.tableView.reloadData()
                }
                
                if !viewModel.isEventIDValid() { //if event id is not valid reset
                    viewModel.fetchMessageWithReset(time: 0, completion: complete)
                }
                else {
                    viewModel.fetchMessages(time: 0, forceClean: false, isUnread: false, completion: complete)
                }
                
                isFirstQueryOfThisEmptyIndex = false
            }
            self.checkContact()
        }
        
        self.viewModel.getLatestMessagesForOthers()
    }
    
    private func handleNoResultImage() {
        {
            let count =  self.viewModel.sectionCount() > 0 ? self.viewModel.rowCount(section: 0) : 0
            if (count <= 0 && !self.fetchingMessage ) {
                let isNotInInbox = self.viewModel.labelID != Message.Location.inbox.rawValue
                
                self.noResultImage.image = isNotInInbox ? UIImage(named: "mail_folder_no_result_icon") : UIImage(named: "mail_no_result_icon")
                self.noResultImage.isHidden = false
                
                self.noResultMainLabel.attributedText = NSMutableAttributedString(string: isNotInInbox ? LocalString._mailbox_folder_no_result_mail_label : LocalString._mailbox_no_result_main_label, attributes: FontManager.Headline)
                self.noResultMainLabel.isHidden = false
                
                self.noResultSecondaryLabel.attributedText = NSMutableAttributedString(string: isNotInInbox ? LocalString._mailbox_folder_no_result_secondary_label : LocalString._mailbox_no_result_secondary_label, attributes: FontManager.DefaultWeak)
                self.noResultSecondaryLabel.isHidden = false
                
                self.noResultFooterLabel.isHidden = false
            } else {
                self.noResultImage.isHidden = true
                self.noResultMainLabel.isHidden = true
                self.noResultSecondaryLabel.isHidden = true
                self.noResultFooterLabel.isHidden = true
            }
        } ~> .main
    }
    
    private func showRefreshController() {
        let height = tableView.tableFooterView?.frame.height ?? 0
        let count = tableView.visibleCells.count
        guard height == 0 && count == 0 else {return}
        
        // Show refreshControl if there is no bottom loading view
        refreshControl.beginRefreshing()
        self.tableView.setContentOffset(CGPoint(x: 0, y: -refreshControl.frame.size.height), animated: true)
    }
    
    var messageTapped = false
    let serialQueue = DispatchQueue(label: "com.protonamil.messageTapped")
    
    private func getTapped() -> Bool {
        serialQueue.sync {
            let ret = self.messageTapped
            if ret == false {
                self.messageTapped = true
            }
            return ret
        }
    }
    private func updateTapped(status: Bool) {
        serialQueue.sync {
            self.messageTapped = status
        }
    }
    
    private func tappedMassage(_ message: Message) {
        if getTapped() == false {
            guard viewModel.isDrafts() || message.draft else {
                self.coordinator?.go(to: .details)
                self.tableView.indexPathsForSelectedRows?.forEach {
                    self.tableView.deselectRow(at: $0, animated: true)
                }
                self.updateTapped(status: false)
                return
            }
            guard !message.messageID.isEmpty else {
                if self.checkHuman() {
                    //TODO::QA
                    self.coordinator?.go(to: .composeShow)
                }
                self.updateTapped(status: false)
                return
            }
            guard !message.isSending else {
                LocalString._mailbox_draft_is_uploading.alertToast()
                self.tableView.indexPathsForSelectedRows?.forEach {
                    self.tableView.deselectRow(at: $0, animated: true)
                }
                self.updateTapped(status: false)
                return
            }
            
            self.viewModel.messageService.ForcefetchDetailForMessage(message) {_, _, msg, error in
                guard let objectId = msg?.objectID,
                    let message = self.viewModel.object(by: objectId),
                    message.body.isEmpty == false else
                {
                    if error != nil {
                        PMLog.D("error: \(String(describing: error))")
                        let alert = LocalString._unable_to_edit_offline.alertController()
                        alert.addOKAction()
                        self.present(alert, animated: true, completion: nil)
                        self.tableView.indexPathsForSelectedRows?.forEach {
                            self.tableView.deselectRow(at: $0, animated: true)
                        }
                    }
                    self.updateTapped(status: false)
                    return
                }
                
                if self.checkHuman() {
                    self.coordinator?.go(to: .composeShow, sender: message)
                    self.tableView.indexPathsForSelectedRows?.forEach {
                        self.tableView.deselectRow(at: $0, animated: true)
                    }
                }
                self.updateTapped(status: false)
            }
        }
        
    }

    private func setupLeftButtons(_ editingMode: Bool) {
        var leftButtons: [UIBarButtonItem]
        
        if (!editingMode) {
            leftButtons = [self.menuBarButtonItem]
        } else {
            leftButtons = []
        }
        
        self.navigationItem.setLeftBarButtonItems(leftButtons, animated: true)
    }
    
    private func setupNavigationTitle(_ editingMode: Bool) {
        if (editingMode) {
            let count = self.viewModel.selectedIDs.count
            self.setNavigationTitleText("\(count) " + LocalString._selected_navogationTitle)
        } else {
            self.setNavigationTitleText(viewModel.localizedNavigationTitle)
        }
    }
    
    private func BarItem(image: UIImage?, action: Selector? ) -> UIBarButtonItem {
       return  UIBarButtonItem(image: image, style: UIBarButtonItem.Style.plain, target: self, action: action)
    }
    
    private func setupRightButtons(_ editingMode: Bool) {
        var rightButtons: [UIBarButtonItem] = []
        
        if (!editingMode) {
            if (self.composeBarButtonItem == nil) {
                let button = Asset.composeIcon.image.toUIBarButtonItem(
                    target: self,
                    action: #selector(composeButtonTapped),
                    tintColor: UIColorManager.Shade0,
                    backgroundColor: UIColorManager.InteractionStrong,
                    backgroundSquareSize: 40,
                    isRound: true
                )
                self.composeBarButtonItem = button
                self.composeBarButtonItem.accessibilityLabel = LocalString._composer_compose_action
            }
            
            if (self.searchBarButtonItem == nil) {
                let button = Asset.searchIcon.image.toUIBarButtonItem(
                    target: self,
                    action: #selector(searchButtonTapped),
                    tintColor: UIColorManager.IconNorm,
                    backgroundColor: UIColorManager.InteractionWeak,
                    backgroundSquareSize: 40,
                    isRound: true
                )
                self.searchBarButtonItem = button
                self.searchBarButtonItem.accessibilityLabel = LocalString._general_search_placeholder
            }
            
            rightButtons = [self.composeBarButtonItem, self.searchBarButtonItem]
        } else {
            if self.cancelBarButtonItem == nil {
                self.cancelBarButtonItem = UIBarButtonItem(title: LocalString._general_cancel_button,
                                                           style: UIBarButtonItem.Style.plain,
                                                           target: self,
                                                           action: #selector(cancelButtonTapped))
                self.cancelBarButtonItem.tintColor = UIColorManager.BrandNorm
            }
            
            rightButtons = [self.cancelBarButtonItem]
        }
        
        self.navigationItem.setRightBarButtonItems(rightButtons, animated: true)
    }
    
    private func hideCheckOptions() {
        self.listEditing = false
        if let indexPathsForVisibleRows = self.tableView.indexPathsForVisibleRows {
            self.tableView.reloadRows(at: indexPathsForVisibleRows, with: .automatic)
        }
    }

    private func enterListEditingMode(indexPath: IndexPath) {
        self.listEditing = true

        guard let visibleRowsIndexPaths = self.tableView.indexPathsForVisibleRows else { return }
        visibleRowsIndexPaths.forEach { visibleRowIndexPath in
            let visibleCell = self.tableView.cellForRow(at: visibleRowIndexPath)
            guard let messageCell = visibleCell as? NewMailboxMessageCell else { return }
            messageCellPresenter.presentSelectionStyle(style: .selection(isSelected: false), in: messageCell.customView)
            guard indexPath == visibleRowIndexPath else { return }
            tableView(tableView, didSelectRowAt: indexPath)
        }

        PMLog.D("Long press on table view at row \(indexPath.row)")
    }
    
    private func showCheckOptions(_ longPressGestureRecognizer: UILongPressGestureRecognizer) {
        let point: CGPoint = longPressGestureRecognizer.location(in: self.tableView)
        let indexPath: IndexPath? = self.tableView.indexPathForRow(at: point)
        guard let touchedRowIndexPath = indexPath,
              longPressGestureRecognizer.state == .began && listEditing == false else { return }
        enterListEditingMode(indexPath: touchedRowIndexPath)
    }
    
    private func updateNavigationController(_ editingMode: Bool) {
        self.setupLeftButtons(editingMode)
        self.setupNavigationTitle(editingMode)
        self.setupRightButtons(editingMode)
    }
 
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        // TODO: refactor SearchViewController to have Coordinator and properly inject this hunk
        if let search = (segue.destination as? UINavigationController)?.topViewController as? SearchViewController {
            search.user = self.viewModel.user
        }
        super.prepare(for: segue, sender: sender)
    }
    
    private func handleUpdateAlert() {
        if self.viewModel.shouldShowUpdateAlert() {
            let alertVC = UIAlertController(title: LocalString._ios10_update_title, message: LocalString._ios10_update_body, preferredStyle: .alert)
            alertVC.addOKAction { (_) in
                self.viewModel.setiOS10AlertIsShown()
            }
            self.present(alertVC, animated: true, completion: nil)
        }
    }
    
    private func retry(delay: Double = 0) {
        // When network reconnect, the DNS data seems will miss at a short time
        // Delay 5 seconds to retry can prevent some relative error
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.getLatestMessages()
        }
    }
    
    private func updateUnreadButton() {
        let unread = viewModel.lastUpdateTime()?.unread ?? 0
        let isInUnreadFilter = unreadFilterButton.isSelected
        unreadFilterButton.backgroundColor = isInUnreadFilter ? UIColorManager.BrandNorm : UIColorManager.BackgroundSecondary
        unreadFilterButton.isHidden = isInUnreadFilter ? false : unread == 0
        let number = unread > 9999 ? " +9999" : "\(unread)"

        if isInUnreadFilter {
            var selectedAttributes = FontManager.Caption
            selectedAttributes[.foregroundColor] = UIColorManager.TextInverted.cgColor

            unreadFilterButton.setAttributedTitle("\(number) \(LocalString._unread_action) ".apply(style: selectedAttributes),
                                                  for: .selected)
        } else {
            var normalAttributes = FontManager.Caption
            normalAttributes[.foregroundColor] = UIColorManager.BrandNorm.cgColor

            unreadFilterButton.setAttributedTitle("\(number) \(LocalString._unread_action) ".apply(style: normalAttributes),
                                                  for: .normal)
        }

        let titleWidth = unreadFilterButton.titleLabel?.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width ?? 0.0
        let width = titleWidth + 16 + (isInUnreadFilter ? 16 : 0)
        unreadFilterButtonWidth.constant = width
    }
    
    private func updateLastUpdateTimeLabel() {
        if let status = self.lastNetworkStatus, status == .NotReachable {
            var attribute = FontManager.CaptionWeak
            attribute[.foregroundColor] = UIColorManager.NotificationError
            updateTimeLabel.attributedText = NSAttributedString(string: LocalString._mailbox_offline_text, attributes: attribute)
            return
        }
        
        let timeText = self.viewModel.getLastUpdateTimeText()
        updateTimeLabel.attributedText = NSAttributedString(string: timeText, attributes: FontManager.CaptionWeak)
    }

    private func configureBannerContainer() {
        let bannerContainer = UIView(frame: .zero)

        view.addSubview(bannerContainer)
        view.bringSubviewToFront(topActionsView)

        [
            bannerContainer.topAnchor.constraint(equalTo: topActionsView.bottomAnchor),
            bannerContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            bannerContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor)
        ].activate()

        self.bannerContainer = bannerContainer
    }

    private func showInternetConnectionBanner() {
        guard let container = bannerContainer, isInternetBannerPresented == false else { return }
        hideAllBanners()
        let banner = MailBannerView()

        container.addSubview(banner)

        banner.label.attributedText = LocalString._banner_no_internet_connection
            .apply(style: FontManager.body3RegularTextInverted)

        [
            banner.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            banner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ].activate()

        bannerShowConstrain = container.topAnchor.constraint(equalTo: banner.topAnchor)

        view.layoutIfNeeded()

        bannerShowConstrain?.isActive = true

        isInternetBannerPresented = true
        tableView.contentInset.top = banner.frame.size.height

        UIView.animate(withDuration: 0.25) { [weak self] in
            self?.view.layoutIfNeeded()

            guard self?.tableView.contentOffset.y == 0 else { return }
            self?.tableView.contentOffset.y = -banner.frame.size.height
        }
    }

    private func hideAllBanners() {
        view.subviews
            .compactMap { $0 as? PMBanner }
            .forEach { $0.dismiss(animated: true) }
    }

    private func hideInternetConnectionBanner() {
        guard isInternetBannerPresented == true, isHidingBanner == false else { return }
        isHidingBanner = true
        isInternetBannerPresented = false
        bannerShowConstrain?.isActive = false
        UIView.animate(withDuration: 0.25, animations: { [weak self] in
            self?.view.layoutIfNeeded()
            self?.bannerContainer?.frame.size.height = 0
            self?.tableView.contentInset.top = .zero
        }, completion: { _ in
            self.bannerContainer?.subviews.forEach { $0.removeFromSuperview() }
            self.isHidingBanner = false
        })
    }

    private func handleShadow(isScrolled: Bool) {
        isScrolled ? topActionsView.layer.apply(shadow: .default) : topActionsView.layer.clearShadow()
    }

    private func deleteExpiredMessages() {
        viewModel.user.messageService.deleteExpiredMessage(completion: nil)
    }
}

// MARK: - Action bar
extension MailboxViewController {
    private func showActionBar() {
        guard self.mailActionBar == nil else {
            return
        }
        let actions = self.viewModel.getActionTypes()
        var actionItems: [PMActionBarItem] = []
        
        for (key, action) in actions.enumerated() {
            
            let actionHandler: (PMActionBarItem) -> Void = { _ in
                if action == .more {
                    self.moreButtonTapped()
                } else {
                    guard !self.viewModel.selectedIDs.isEmpty else {
                        self.showNoEmailSelected(title: LocalString._warning)
                        return
                    }
                    switch action {
                    case .delete:
                        self.showDeleteAlert { [weak self] in
                            guard let `self` = self else { return }
                            self.viewModel.handleBarActions(action,
                                                            selectedIDs: NSMutableSet(set: self.viewModel.selectedIDs))
                            self.showMessageMoved(title: LocalString._messages_has_been_deleted)
                        }
                    case .moveTo:
                        self.folderButtonTapped()
                    case .labelAs:
                        self.labelButtonTapped()
                    default:
                        let temp = NSMutableSet(set: self.viewModel.selectedIDs)
                        self.viewModel.handleBarActions(action, selectedIDs: temp)
                        self.showMessageMoved(title: LocalString._messages_has_been_moved)
                        self.cancelButtonTapped()
                    }
                }
            }
            
            if key == actions.startIndex {
                let barItem = PMActionBarItem(icon: action.iconImage,
                                              text: action.name,
                                              handler: actionHandler)
                actionItems.append(barItem)
            } else {
                let barItem = PMActionBarItem(icon: action.iconImage,
                                              backgroundColor: .clear,
                                              handler: actionHandler)
                actionItems.append(barItem)
            }
        }
        let separator = PMActionBarItem(width: 1,
                                        verticalPadding: 6,
                                        color: UIColorManager.FloatyText)
        actionItems.insert(separator, at: 1)
        self.mailActionBar = PMActionBar(items: actionItems,
                                         backgroundColor: UIColorManager.FloatyBackground,
                                         floatingHeight: 42.0,
                                         width: .fit,
                                         height: 48.0)
        self.mailActionBar?.show(at: self)
    }
    
    private func hideActionBar() {
        self.mailActionBar?.dismiss()
        self.mailActionBar = nil
    }
    
    private func hideActionSheet() {
        self.actionSheet?.dismiss(animated: true)
        self.actionSheet = nil
    }

    private func showDeleteAlert(yesHandler: @escaping () -> Void) {
        let messagesCount = viewModel.selectedIDs.count
        let title = messagesCount > 1 ?
            LocalString._messages_delete_confirmation_alert_title :
            LocalString._single_message_delete_confirmation_alert_title
        let message = messagesCount > 1 ?
            LocalString._messages_delete_confirmation_alert_message :
            LocalString._single_message_delete_confirmation_alert_message
        let alert = UIAlertController(
            title: String(format: title, messagesCount),
            message: String(format: message, messagesCount),
            preferredStyle: .alert
        )
        let yes = UIAlertAction(title: LocalString._general_delete_action, style: .destructive) { [weak self] _ in
            yesHandler()
            self?.cancelButtonTapped()
        }
        let cancel = UIAlertAction(title: LocalString._general_cancel_button, style: .cancel) { [weak self] _ in
            self?.cancelButtonTapped()
        }
        [yes, cancel].forEach(alert.addAction)
        present(alert, animated: true, completion: nil)
    }

    func moreButtonTapped() {
        mailListActionSheetPresenter.present(
            on: navigationController ?? self,
            viewModel: viewModel.actionSheetViewModel,
            action: { [weak self] in
                self?.viewModel.handleActionSheetAction($0)
                self?.handleActionSheetAction($0)
            }
        )
    }
}

extension MailboxViewController: LabelAsActionSheetPresentProtocol {
    var labelAsActionHandler: LabelAsActionSheetProtocol {
        return viewModel
    }

    func labelButtonTapped() {
        guard !viewModel.selectedIDs.isEmpty else {
            showNoEmailSelected(title: LocalString._apply_labels)
            return
        }

        showLabelAsActionSheet(messages: viewModel.selectedMessages)
    }

    private func showLabelAsActionSheet(messages: [Message]) {
        let labelAsViewModel = LabelAsActionSheetViewModel(menuLabels: labelAsActionHandler.getLabelMenuItems(),
                                                           messages: messages)

        labelAsActionSheetPresenter
            .present(on: self.navigationController ?? self,
                     viewModel: labelAsViewModel,
                     addNewLabel: { [weak self] in
                        self?.coordinator?.pendingActionAfterDismissal = { [weak self] in
                            self?.showLabelAsActionSheet(messages: messages)
                        }
                        self?.coordinator?.go(to: .newLabel)
                     },
                     selected: { [weak self] menuLabel, isOn in
                        self?.labelAsActionHandler.updateSelectedLabelAsDestination(menuLabel: menuLabel, isOn: isOn)
                     },
                     cancel: { [weak self] isHavingUnsavedChanges in
                        if isHavingUnsavedChanges {
                            self?.showDiscardAlert(handleDiscard: {
                                self?.labelAsActionHandler.updateSelectedLabelAsDestination(menuLabel: nil, isOn: false)
                                self?.dismissActionSheet()
                            })
                        } else {
                            self?.dismissActionSheet()
                        }
                     },
                     done: { [weak self] isArchive, currentOptionsStatus in
                        self?.labelAsActionHandler
                            .handleLabelAsAction(messages: messages,
                                                 shouldArchive: isArchive,
                                                 currentOptionsStatus: currentOptionsStatus)
                        self?.dismissActionSheet()
                        self?.cancelButtonTapped()
                     })
    }
}

extension MailboxViewController: MoveToActionSheetPresentProtocol {
    var moveToActionHandler: MoveToActionSheetProtocol {
        return viewModel
    }

    func folderButtonTapped() {
        guard !self.viewModel.selectedIDs.isEmpty else {
            showNoEmailSelected(title: LocalString._apply_labels)
            return
        }

        let isEnableColor = viewModel.user.isEnableFolderColor
        let isInherit = viewModel.user.isInheritParentFolderColor
        showMoveToActionSheet(messages: viewModel.selectedMessages,
                              isEnableColor: isEnableColor,
                              isInherit: isInherit)
    }

    private func showMoveToActionSheet(messages: [Message], isEnableColor: Bool, isInherit: Bool) {
        let moveToViewModel =
            MoveToActionSheetViewModel(menuLabels: moveToActionHandler.getFolderMenuItems(),
                                       messages: messages,
                                       isEnableColor: isEnableColor,
                                       isInherit: isInherit,
                                       labelId: viewModel.labelId)
        moveToActionSheetPresenter
            .present(on: self.navigationController ?? self,
                     viewModel: moveToViewModel,
                     addNewFolder: { [weak self] in
                        self?.coordinator?.pendingActionAfterDismissal = { [weak self] in
                            self?.showMoveToActionSheet(messages: messages, isEnableColor: isEnableColor, isInherit: isInherit)
                        }
                        self?.coordinator?.go(to: .newFolder)
                     },
                     selected: { [weak self] menuLabel, isOn in
                        self?.moveToActionHandler.updateSelectedMoveToDestination(menuLabel: menuLabel, isOn: isOn)
                     },
                     cancel: { [weak self] isHavingUnsavedChanges in
                        if isHavingUnsavedChanges {
                            self?.showDiscardAlert(handleDiscard: {
                                self?.moveToActionHandler.updateSelectedMoveToDestination(menuLabel: nil, isOn: false)
                                self?.dismissActionSheet()
                            })
                        } else {
                            self?.dismissActionSheet()
                        }
                     },
                     done: { [weak self] isHavingUnsavedChanges in
                        defer {
                            self?.dismissActionSheet()
                            self?.cancelButtonTapped()
                        }
                        guard isHavingUnsavedChanges else {
                            return
                        }
                        self?.moveToActionHandler.handleMoveToAction(messages: messages)
                     })
    }

    private func handleActionSheetAction(_ action: MailListSheetAction) {
        switch action {
        case .dismiss:
            dismissActionSheet()
        case .remove, .moveToArchive, .moveToSpam, .moveToInbox:
            showMessageMoved(title: LocalString._messages_has_been_moved)
            cancelButtonTapped()
        case .markRead, .markUnread, .star, .unstar:
            cancelButtonTapped()
        case .delete:
            showDeleteAlert { [weak self] in
                guard let `self` = self else { return }
                self.viewModel.delete(IDs: NSMutableSet(set: self.viewModel.selectedIDs))
            }
        case .labelAs:
            labelButtonTapped()
        case .moveTo:
            folderButtonTapped()
        }
    }
}

// MARK: - LablesViewControllerDelegate
extension MailboxViewController : LablesViewControllerDelegate {
    func dismissed() {
    }
    
    func apply(type: LabelFetchType) {
        self.cancelButtonTapped() // this will finish multiselection mode
        
        if type == .label {
            showMessageMoved(title: LocalString._messages_labels_applied)
        } else if type == .folder {
            showMessageMoved(title: LocalString._messages_has_been_moved)
        }
    }
}

// MARK: - MailboxCaptchaVCDelegate
extension MailboxViewController : MailboxCaptchaVCDelegate {
    
    func cancel() {
        isCheckingHuman = false
    }
    
    func done() {
        isCheckingHuman = false
        self.viewModel.isRequiredHumanCheck = false
    }
}

// MARK: - Show banner or alert
extension MailboxViewController {
    private func showErrorMessage(_ error: NSError?) {
        guard let error = error else { return }
        let banner = PMBanner(message: error.localizedDescription, style: PMBannerNewStyle.error, dismissDuration: Double.infinity)
        banner.show(at: .top, on: self)
    }

    private func showTimeOutErrorMessage() {
        let banner = PMBanner(message: LocalString._general_request_timed_out, style: PMBannerNewStyle.error, dismissDuration: 5.0)
        banner.addButton(text: LocalString._retry) { _ in
            banner.dismiss()
            self.getLatestMessages()
        }
        banner.show(at: .top, on: self)
    }

    private func showNoInternetErrorMessage() {
        let banner = PMBanner(message: LocalString._general_no_connectivity_detected, style: PMBannerNewStyle.error, dismissDuration: 5.0)
        banner.addButton(text: LocalString._retry) { _ in
            banner.dismiss()
            self.getLatestMessages()
        }
        banner.show(at: .top, on: self)
    }

    internal func showOfflineErrorMessage(_ error : NSError?) {
        let banner = PMBanner(message: error?.localizedDescription ?? LocalString._general_pm_offline, style: PMBannerNewStyle.error, dismissDuration: 5.0)
        banner.addButton(text: LocalString._retry) { _ in
            banner.dismiss()
            self.getLatestMessages()
        }
        banner.show(at: .top, on: self)
    }

    private func show503ErrorMessage(_ error : NSError?) {
        let banner = PMBanner(message: LocalString._general_api_server_not_reachable, style: PMBannerNewStyle.error, dismissDuration: 5.0)
        banner.addButton(text: LocalString._retry) { _ in
            banner.dismiss()
            self.getLatestMessages()
        }
        banner.show(at: .top, on: self)
    }

    private func showError(_ error : NSError) {
        let banner = PMBanner(message: "We could not connect to the servers. Pull down to retry.", style: PMBannerNewStyle.error, dismissDuration: 5.0)
        banner.addButton(text: "Learn more") { _ in
            banner.dismiss()
            self.goTroubleshoot()
        }
        banner.show(at: .top, on: self)
    }
    
    private func showNewMessageCount(_ count : Int) {
        guard self.needToShowNewMessage, count > 0 else { return }
        self.needToShowNewMessage = false
        self.newMessageCount = 0
        let message = count == 1 ? LocalString._messages_you_have_new_email : String(format: LocalString._messages_you_have_new_emails_with, count)
        message.alertToastBottom()
    }
    
    private func hideTopMessage() {
        self.topMessageView?.remove(animated: true)
    }
}

// MARK: - Handle Network status changed
extension MailboxViewController {
    @objc private func reachabilityChanged(_ note : Notification) {
        if let currentReachability = note.object as? Reachability {
            self.updateInterface(reachability: currentReachability)
        } else {
            if let status = note.object as? Int, sharedInternetReachability.currentReachabilityStatus() != .NotReachable {
                PMLog.D("\(status)")
                DispatchQueue.main.async {
                    if status == 0 { //time out
                        self.showTimeOutErrorMessage()
                    } else if status == 1 { //not reachable
                        self.showNoInternetErrorMessage()
                    }
                }
            }
        }
    }
    
    private func updateInterface(reachability: Reachability) {
        let netStatus = reachability.currentReachabilityStatus()
        switch netStatus {
        case .NotReachable:
            PMLog.D("Access Not Available")
            self.showInternetConnectionBanner()
        case .ReachableViaWWAN:
            PMLog.D("Reachable WWAN")
            self.hideInternetConnectionBanner()
            self.afterNetworkChange(status: netStatus)
        case .ReachableViaWiFi:
            PMLog.D("Reachable WiFi")
            self.hideInternetConnectionBanner()
            self.afterNetworkChange(status: netStatus)
        default:
            PMLog.D("Reachable default unknow")
        }
        lastNetworkStatus = netStatus
        
        self.updateLastUpdateTimeLabel()
    }
    
    private func afterNetworkChange(status: NetworkStatus) {
        guard let oldStatus = lastNetworkStatus else {
            return
        }
        
        guard oldStatus == .NotReachable else {
            return
        }
        
        if status == .ReachableViaWWAN || status == .ReachableViaWiFi {
            self.retry(delay: 5)
        }
    }
}

// MARK: - UITableViewDataSource
extension MailboxViewController: UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int {
        if self.shouldAnimateSkeletonLoading {
            return 1
        } else {
            return self.viewModel.sectionCount()
        }
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if self.shouldAnimateSkeletonLoading {
            return 10
        } else {
            return self.viewModel.rowCount(section: section)
        }
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cellIdentifier = self.shouldAnimateSkeletonLoading ? MailBoxSkeletonLoadingCell.Constant.identifier : NewMailboxMessageCell.defaultID()
        let cell = tableView.dequeueReusableCell(withIdentifier: cellIdentifier, for: indexPath)
        
        if self.shouldAnimateSkeletonLoading {
            cell.showAnimatedGradientSkeleton()
        } else {
            self.configure(cell: cell, indexPath: indexPath)
        }
        return cell

    }
}


// MARK: - NSFetchedResultsControllerDelegate

extension MailboxViewController: NSFetchedResultsControllerDelegate {
    func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        if controller == self.viewModel.labelFetchedResults {
            tableView.reloadData()
            return
        }
        
        if controller == self.viewModel.unreadFetchedResult {
            self.updateUnreadButton()
            return
        }
        
        self.tableView.endUpdates()
        if self.refreshControl.isRefreshing {
            self.refreshControl.endRefreshing()
        }
        self.showNewMessageCount(self.newMessageCount)
        self.updateLastUpdateTimeLabel()
        self.handleNoResultImage()
    }
    
    func controllerWillChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        if controller == self.viewModel.labelFetchedResults || controller == self.viewModel.unreadFetchedResult {
            return
        }
        
        if self.shouldAnimateSkeletonLoading {
            self.shouldAnimateSkeletonLoading = false
            self.updateTimeLabel.hideSkeleton()
            self.unreadFilterButton.titleLabel?.hideSkeleton()
            self.updateUnreadButton()
            
            self.tableView.reloadData()
        }
        
        tableView.beginUpdates()
    }
    
    func controller(_ controller: NSFetchedResultsController<NSFetchRequestResult>, didChange sectionInfo: NSFetchedResultsSectionInfo, atSectionIndex sectionIndex: Int, for type: NSFetchedResultsChangeType) {
        if controller == self.viewModel.labelFetchedResults || controller == self.viewModel.unreadFetchedResult {
            return
        }
        switch(type) {
        case .delete:
            tableView.deleteSections(IndexSet(integer: sectionIndex), with: .fade)
        case .insert:
            tableView.insertSections(IndexSet(integer: sectionIndex), with: .fade)
        default:
            return
        }
    }
    
    func controller(_ controller: NSFetchedResultsController<NSFetchRequestResult>, didChange anObject: Any, at indexPath: IndexPath?, for type: NSFetchedResultsChangeType, newIndexPath: IndexPath?) {
        if controller == self.viewModel.labelFetchedResults || controller == self.viewModel.unreadFetchedResult {
            return
        }
        switch(type) {
        case .delete:
            if let indexPath = indexPath {
                tableView.deleteRows(at: [indexPath], with: .fade)
            }
        case .insert:
            if let newIndexPath = newIndexPath {
                tableView.insertRows(at: [newIndexPath], with: .fade)
                if self.needToShowNewMessage == true {
                    if let newMsg = anObject as? Message {
                        if let msgTime = newMsg.time, newMsg.unRead {
                            if let updateTime = viewModel.lastUpdateTime() {
                                if msgTime.compare(updateTime.startTime) != ComparisonResult.orderedAscending {
                                    self.newMessageCount += 1
                                }
                            }
                        }
                    }
                }
            }
        case .update:
            //#3 is active
            /// # 1
            if let indexPath = indexPath {
                self.tableView.reloadRows(at: [indexPath], with: .fade)
            }
            
//            if let newIndexPath = newIndexPath {
//                self.tableView.reloadRows(at: [newIndexPath], with: .fade)
//            }
            
            /// #2
//            if let indexPath = indexPath {
//                let cell = tableView.cellForRow(at: indexPath)
//                self.configure(cell: cell, indexPath: indexPath)
//            }

//            if let newIndexPath = newIndexPath {
//                let cell = tableView.cellForRow(at: newIndexPath)
//                self.configure(cell: cell, indexPath: newIndexPath)
//            }

            /// #3
//            if let indexPath = indexPath, let newIndexPath = newIndexPath {
//                let cell = tableView.cellForRow(at: indexPath)
//                self.configure(cell: cell, indexPath: newIndexPath)
//            }/
        case .move:
            if let indexPath = indexPath, let newIndexPath = newIndexPath {
                tableView.deleteRows(at: [indexPath], with: .fade)
                tableView.insertRows(at: [newIndexPath], with: .fade)
            }
            break
        default:
            return
        }
    }
}


// MARK: - UITableViewDelegate

extension MailboxViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard let current = self.viewModel.item(index: indexPath) else {
            return
        }
        
        if let updateTime = viewModel.lastUpdateTime(), let currentTime = current.time {
            
            let endTime = self.isShowingUnreadMessageOnly ? updateTime.unreadEndTime : updateTime.endTime
            let totalMessage = self.isShowingUnreadMessageOnly ? Int(updateTime.unread) : Int(updateTime.total)
            let isNew = self.isShowingUnreadMessageOnly ? updateTime.isUnreadNew : updateTime.isNew
            
            
            let isOlderMessage = endTime.compare(currentTime) != ComparisonResult.orderedAscending
            let loadMore = self.viewModel.loadMore(index: indexPath)
            if  (isOlderMessage || loadMore) && !self.fetchingOlder {
                let sectionCount = self.viewModel.rowCount(section: indexPath.section)
                let recordedCount = totalMessage
                //here need add a counter to check if tried too many times make one real call in case count not right
                if isNew || recordedCount > sectionCount {
                    self.fetchingOlder = true
                    if !refreshControl.isRefreshing {
                        self.tableView.showLoadingFooter()
                    }
                    let unixTimt: Int = (endTime == Date.distantPast ) ? 0 : Int(endTime.timeIntervalSince1970)
                    self.viewModel.fetchMessages(time: unixTimt, forceClean: false, isUnread: self.isShowingUnreadMessageOnly, completion: { (task, response, error) -> Void in
                        self.tableView.hideLoadingFooter()
                        self.fetchingOlder = false
                        self.checkHuman()
                    })
                }
            }
        }
    }
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if self.shouldAnimateSkeletonLoading {
            return 90.0
        } else {
            return UITableView.automaticDimension
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let message = viewModel.item(index: indexPath) else { return }
        if listEditing {
            let messageAlreadySelected = self.viewModel.selectionContains(id: message.messageID)
            let selectionAction = messageAlreadySelected ? viewModel.removeSelected : viewModel.select
            selectionAction(message.messageID)

            if viewModel.selectedIDs.isEmpty {
                hideActionBar()
            }

            if !viewModel.selectedIDs.isEmpty, mailActionBar == nil {
                showActionBar()
            }

            // update checkbox state
            if let mailboxCell = tableView.cellForRow(at: indexPath) as? NewMailboxMessageCell {
                messageCellPresenter.presentSelectionStyle(
                    style: .selection(isSelected: !messageAlreadySelected),
                    in: mailboxCell.customView
                )
            }

            tableView.deselectRow(at: indexPath, animated: true)
            self.setupNavigationTitle(true)
        } else {
            self.indexPathForSelectedRow = indexPath
            self.tappedMassage(message)
        }
    }

}

extension MailboxViewController: NewMailboxMessageCellDelegate {
    func didSelectButtonStatusChange(id: String?) {
        let tappedCell = tableView.visibleCells
            .compactMap { $0 as? NewMailboxMessageCell }
            .first(where: { $0.id == id })
        guard let cell = tappedCell, let indexPath = tableView.indexPath(for: cell) else { return }

        if !listEditing {
            self.enterListEditingMode(indexPath: indexPath)
            updateNavigationController(listEditing)
        } else {
            tableView(self.tableView, didSelectRowAt: indexPath)
        }
    }
}

extension MailboxViewController {
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if refreshControl.isRefreshing {
            self.pullDown()
        }
    }

    private func configureUnreadFilterButton() {
        self.unreadFilterButton.setTitleColor(UIColorManager.BrandNorm, for: .normal)
        self.unreadFilterButton.setTitleColor(UIColorManager.BackgroundNorm, for: .selected)
        self.unreadFilterButton.setImage(Asset.mailLabelCrossIcon.image, for: .selected)
        self.unreadFilterButton.semanticContentAttribute = .forceRightToLeft
        self.unreadFilterButton.titleLabel?.isSkeletonable = true
        self.unreadFilterButton.titleLabel?.font = UIFont.systemFont(ofSize: 13.0)
        self.unreadFilterButton.translatesAutoresizingMaskIntoConstraints = false
        self.unreadFilterButton.layer.cornerRadius = self.unreadFilterButton.frame.height / 2
        self.unreadFilterButton.layer.masksToBounds = true
        self.unreadFilterButton.backgroundColor = UIColorManager.BackgroundSecondary
        self.unreadFilterButton.isSelected = viewModel.isCurrentUserSelectedUnreadFilterInInbox
    }
}

extension MailboxViewController: Deeplinkable {
    var deeplinkNode: DeepLink.Node {
        return DeepLink.Node(name: String(describing: MailboxViewController.self), value: self.viewModel.labelID)
    }
}

extension MailboxViewController: SkeletonTableViewDataSource {
    func collectionSkeletonView(_ skeletonView: UITableView, cellIdentifierForRowAt indexPath: IndexPath) -> ReusableCellIdentifier {
        return MailBoxSkeletonLoadingCell.Constant.identifier
    }
}
