//
//  EncryptedSearchService.swift
//  ProtonMail
//
//  Created by Ralph Ankele on 05.07.21.
//  Copyright © 2021 ProtonMail. All rights reserved.
//

import Foundation
import CoreData
import SwiftSoup
import SQLite
import Crypto
import CryptoKit
import Network
import Groot
import BackgroundTasks
//import Reachability

import ProtonCore_Services
import ProtonCore_DataModel
import UIKit
import SwiftUI
import ProtonCore_UIFoundations

extension Array {
    func chunks(_ chunkSize: Int) -> [[Element]] {
        return stride(from: 0, to: self.count, by: chunkSize).map {
            Array(self[$0..<Swift.min($0 + chunkSize, self.count)])
        }
    }
}

public class EncryptedSearchService {
    // Instance of Singleton
    static let shared = EncryptedSearchService()

    // Set initializer to private - Singleton
    private init(){
        let users: UsersManager = sharedServices.get(by: UsersManager.self)
        if users.firstUser != nil {
            user = users.firstUser //should return the currently active user
            messageService = user.messageService
            self.apiService = user.apiService
            self.userDataSource = user.messageService.userDataSource
        }

        self.timeFormatter.allowedUnits = [.hour, .minute, .second]
        self.timeFormatter.unitsStyle = .abbreviated

        // Enable temperature monitoring
        self.registerForTermalStateChangeNotifications()
        // Enable battery level monitoring
        self.registerForPowerStateChangeNotifications()
    }

    // State variables
    enum EncryptedSearchIndexState: Int {
        case disabled = 0
        case partial = 1
        case lowstorage = 2
        case downloading = 3
        case paused = 4
        case refresh = 5
        case complete = 6
        case undetermined = 7
        case background = 8     // Indicates that the index is currently build in the background
        case backgroundStopped = 9  // Indicates that the index building has been paused while building in the background
    }

    // Device dependent variables
    internal var lowStorageLimit: Int = 100_000_000     // 100 MB
    internal var slowDownIndexBuilding: Bool = false
    internal var viewModel: SettingsEncryptedSearchViewModel? = nil
    @available(iOS 12, *)
    internal lazy var networkMonitor: NWPathMonitor? = nil
    internal lazy var networkMonitoringQueue: DispatchQueue? = nil
    //internal lazy var networkMonitorAllIOS: InternetConnectionStatusProvider? = nil
    internal var pauseIndexingDueToNetworkConnectivityIssues: Bool = false
    internal var pauseIndexingDueToWiFiNotDetected: Bool = false
    internal var pauseIndexingDueToOverheating: Bool = false
    internal var pauseIndexingDueToLowBattery: Bool = false
    internal var indexBuildingTimer: Timer? = nil
    internal var estimateIndexTimeRounds: Int = 0
    internal var eventsWhileIndexing: [MessageAction]? = []
    internal var messageIndexingQueue: OperationQueue? = nil
    internal var downloadPageQueue: OperationQueue? = nil
    internal var pageSize: Int = 150    // default = maximum page size
    internal var indexingSpeed: Int = OperationQueue.defaultMaxConcurrentOperationCount // default = maximum operation count
    internal var slowDownIndexingCounter: Int = 0
    internal var addTimeOutWhenIndexingAsMemoryExceeds: Bool = false
    internal var deletingCacheInProgress: Bool = false

    #if !APP_EXTENSION
    internal var searchViewModel: SearchViewModel? = nil
    #endif
    internal var slowSearchTimer: Timer? = nil
    internal var searchState: EncryptedsearchSearchState? = nil
    internal var isFirstSearch: Bool = true
    public var isSearching: Bool = false    // indicates that a search is currently active
    internal var searchResultPageSize: Int = 50
    //internal var numberOfResultsFoundByCachedSearch: Int = 0
    //internal var numberOfResultsFoundByIndexSearch: Int = 0
    internal var numberOfResultsFoundBySearch: Int = 0
    internal var searchQuery: [String] = []

    // Independent variables
    let timeFormatter = DateComponentsFormatter()
    var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    var encryptedSearchBGProcessingTaskRegistered: Bool = false
    var encryptedSearchBGAppRefreshTaskRegistered: Bool = false
    internal var user: UserManager!
    internal var messageService: MessageDataService? = nil
    internal var apiService: APIService? = nil
    internal var userDataSource: UserDataSource? = nil
}

extension EncryptedSearchService {
    func updateViewModelIfNeeded(viewModel: SettingsEncryptedSearchViewModel) {
        self.viewModel = viewModel
    }

    func resizeSearchIndex(userID: String) -> Void {
        guard EncryptedSearchIndexService.shared.checkIfSearchIndexExists(for: userID) else {
            print("Search index for user \(userID) does not exist. No need to resize.")
            return
        }

        let sizeOfSearchIndex: Int64 = EncryptedSearchIndexService.shared.getSizeOfSearchIndex(for: userID).asInt64!
        if userCachedStatus.storageLimit == -1 {
            // If indexing is currently in progress, we just change the limit, but don't need to restart indexing
            let expectedESStates: [EncryptedSearchIndexState] = [.complete, .partial]
            if expectedESStates.contains(EncryptedSearchService.shared.getESState(userID: userID)) {
                DispatchQueue.global(qos: .userInitiated).async {
                    self.getTotalMessages(userID: userID) {
                        let numberOfMessageInSearchIndex: Int = EncryptedSearchIndexService.shared.getNumberOfEntriesInSearchIndex(for: userID)
                        // Check if there a new message on the server
                        if numberOfMessageInSearchIndex < userCachedStatus.encryptedSearchTotalMessages {
                            self.restartIndexBuilding(userID: userID)
                        } else {
                            print("No new messages on the server. No need to resize!")
                        }
                    }
                }
            }
        } else {
            // Search index is larger as the limit -> shrink search index
            if sizeOfSearchIndex > userCachedStatus.storageLimit {
                DispatchQueue.global(qos: .userInitiated).async {
                    let success: Bool = EncryptedSearchIndexService.shared.shrinkSearchIndex(userID: userID, expectedSize: userCachedStatus.storageLimit)
                    if success == false {
                        self.setESState(userID: userID, indexingState: .complete)
                    } else {
                        self.setESState(userID: userID, indexingState: .partial)
                        userCachedStatus.encryptedSearchLastMessageTimeIndexed = EncryptedSearchIndexService.shared.getOldestMessageInSearchIndex(for: userID).asInt
                        userCachedStatus.encryptedSearchLastMessageIDIndexed = EncryptedSearchIndexService.shared.getMessageIDOfOldestMessageInSearchIndex(for: userID)
                    }
                }
            }

            // Search index is smaller as storage limit - check if there are some messages that we need to fetch
            if sizeOfSearchIndex < userCachedStatus.storageLimit {
                // If indexing is currently in progress, we just change the limit, but don't need to restart indexing
                let expectedESStates: [EncryptedSearchIndexState] = [.complete, .partial]
                if expectedESStates.contains(EncryptedSearchService.shared.getESState(userID: userID)) {
                    DispatchQueue.global(qos: .userInitiated).async {
                        self.getTotalMessages(userID: userID) {
                            let numberOfMessageInSearchIndex: Int = EncryptedSearchIndexService.shared.getNumberOfEntriesInSearchIndex(for: userID)
                            // Check if there a new message on the server
                            if numberOfMessageInSearchIndex < userCachedStatus.encryptedSearchTotalMessages {
                                self.restartIndexBuilding(userID: userID)
                            } else {
                                print("No new messages on the server. No need to resize!")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Index Building Functions
    // This function is called after login for small accounts (<= 150 messages)
    func forceBuildSearchIndex(userID: String) {
        print("Encrypted Search - force build index")
        // Update API services to current user
        self.updateUserAndAPIServices()

        // Set ES state
        self.setESState(userID: userID, indexingState: .downloading)
        // Enable ES
        userCachedStatus.isEncryptedSearchOn = true
        // For small accounts we enable downloading via mobile data by default
        userCachedStatus.downloadViaMobileData = true
        // Disable popup for ES
        userCachedStatus.isEncryptedSearchAvailablePopupAlreadyShown = true

        // Check if search index db exists - and if not create it
        EncryptedSearchIndexService.shared.createSearchIndexDBIfNotExisting(for: userID)

        // Initialize Operation Queues for indexing
        self.initializeOperationQueues()

        // Speed up indexing if its slowed down
        //self.speedUpIndexing(userID: userID)

        self.getTotalMessages(userID: userID) {
            print("Total messages: ", userCachedStatus.encryptedSearchTotalMessages)
            // If a user has 0 messages, we can simply finish and return
            if userCachedStatus.encryptedSearchTotalMessages == 0 {
                self.setESState(userID: userID, indexingState: .complete)
                self.cleanUpAfterIndexing(userID: userID)
                return
            }

            let numberOfMessageInIndex: Int = EncryptedSearchIndexService.shared.getNumberOfEntriesInSearchIndex(for: userID)
            if numberOfMessageInIndex == 0 {
                print("ES-DEBUG: Build search index completely new")

                // Reset some values
                userCachedStatus.encryptedSearchLastMessageTimeIndexed = 0
                userCachedStatus.encryptedSearchLastMessageIDIndexed = nil
                userCachedStatus.encryptedSearchProcessedMessages = 0
                userCachedStatus.encryptedSearchPreviousProcessedMessages = 0
                userCachedStatus.encryptedSearchNumberOfPauses = 0
                userCachedStatus.encryptedSearchNumberOfInterruptions = 0

                // If there are no message in the search index - build completely new
                DispatchQueue.global(qos: .userInitiated).async {
                    self.downloadAndProcessPage(userID: userID){ [weak self] in
                        self?.checkIfIndexingIsComplete(userID: userID, completionHandler: {})
                    }
                }
            } else if numberOfMessageInIndex == userCachedStatus.encryptedSearchTotalMessages {
                // No new messages on server - set to complete
                self.setESState(userID: userID, indexingState: .complete)

                self.cleanUpAfterIndexing(userID: userID)
            } else {
                print("ES-DEBUG: refresh search index")
                // There are some new messages on the server - refresh the index
                self.refreshSearchIndex(userID: userID)
            }
        }
    }

    func buildSearchIndex(userID: String, viewModel: SettingsEncryptedSearchViewModel) -> Void {
        // Update API services to current user
        self.updateUserAndAPIServices()

        #if !APP_EXTENSION
            if #available(iOS 13, *) {
                self.scheduleNewAppRefreshTask()
                self.scheduleNewBGProcessingTask()
            }
        #endif

        self.viewModel = viewModel
        self.setESState(userID: userID, indexingState: .downloading)

        // Check if search index db exists - and if not create it
        EncryptedSearchIndexService.shared.createSearchIndexDBIfNotExisting(for: userID)

        // Network checks
        if #available(iOS 12, *) {
            // Check network status - enable network monitoring if not available
            print("ES-NETWORK - build search index - enable network monitoring")
            self.registerForNetworkChangeNotifications()
        } else {
            // Fallback on earlier versions
        }

        // Set up timer to estimate time for index building every 2 seconds
        DispatchQueue.main.async {
            userCachedStatus.encryptedSearchIndexingStartTime = CFAbsoluteTimeGetCurrent()
            self.indexBuildingTimer = Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(self.updateRemainingIndexingTime), userInfo: nil, repeats: true)
        }

        // Initialize Operation Queues for indexing
        self.initializeOperationQueues()

        // Speed up indexing if its slowed down
        self.speedUpIndexing(userID: userID)

        self.getTotalMessages(userID: userID) {
            print("Total messages: ", userCachedStatus.encryptedSearchTotalMessages)
            // If a user has 0 messages, we can simply finish and return
            if userCachedStatus.encryptedSearchTotalMessages == 0 {
                self.setESState(userID: userID, indexingState: .complete)
                self.cleanUpAfterIndexing(userID: userID)
                return
            }

            let numberOfMessageInIndex: Int = EncryptedSearchIndexService.shared.getNumberOfEntriesInSearchIndex(for: userID)
            if numberOfMessageInIndex == 0 {
                print("ES-DEBUG: Build search index completely new")

                // Reset some values
                userCachedStatus.encryptedSearchLastMessageTimeIndexed = 0
                userCachedStatus.encryptedSearchLastMessageIDIndexed = nil
                userCachedStatus.encryptedSearchProcessedMessages = 0
                userCachedStatus.encryptedSearchPreviousProcessedMessages = 0
                userCachedStatus.encryptedSearchNumberOfPauses = 0
                userCachedStatus.encryptedSearchNumberOfInterruptions = 0

                // If there are no message in the search index - build completely new
                DispatchQueue.global(qos: .userInitiated).async {
                    self.downloadAndProcessPage(userID: userID){ [weak self] in
                        self?.checkIfIndexingIsComplete(userID: userID, completionHandler: {})
                    }
                }
            } else if numberOfMessageInIndex == userCachedStatus.encryptedSearchTotalMessages {
                // No new messages on server - set to complete
                self.setESState(userID: userID, indexingState: .complete)

                self.cleanUpAfterIndexing(userID: userID)
            } else {
                print("ES-DEBUG: refresh search index")
                // There are some new messages on the server - refresh the index
                self.refreshSearchIndex(userID: userID)
            }
        }
    }

    func restartIndexBuilding(userID: String) -> Void {
        // Set the state to downloading
        self.setESState(userID: userID, indexingState: .downloading)

        // Initialize Operation Queues for indexing
        self.initializeOperationQueues()

        // Speed up indexing if its slowed down
        self.speedUpIndexing(userID: userID)

        // Update API services to current user
        self.updateUserAndAPIServices()

        // Update the UI with refresh state
        self.updateUIWithIndexingStatus(userID: userID)

        // Set processed message to the number of entries in the search index
        userCachedStatus.encryptedSearchProcessedMessages = EncryptedSearchIndexService.shared.getNumberOfEntriesInSearchIndex(for: userID)
        userCachedStatus.encryptedSearchPreviousProcessedMessages = EncryptedSearchIndexService.shared.getNumberOfEntriesInSearchIndex(for: userID)
        // Update last indexed message with the newest message in search index
        userCachedStatus.encryptedSearchLastMessageTimeIndexed = EncryptedSearchIndexService.shared.getOldestMessageInSearchIndex(for: userID).asInt
        userCachedStatus.encryptedSearchLastMessageIDIndexed = EncryptedSearchIndexService.shared.getMessageIDOfOldestMessageInSearchIndex(for: userID)

        // reset counter to stabilize indexing estimate
        self.estimateIndexTimeRounds = 0
        self.viewModel?.estimatedTimeRemaining.value = nil

        // Restart index building timers
        DispatchQueue.main.async {
            userCachedStatus.encryptedSearchIndexingStartTime = CFAbsoluteTimeGetCurrent()
            if self.indexBuildingTimer != nil {
                self.indexBuildingTimer?.invalidate()
                self.indexBuildingTimer = nil
            }
            self.indexBuildingTimer = Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(self.updateRemainingIndexingTime), userInfo: nil, repeats: true)
        }

        // Enable network monitoring - if not already enabled
        if #available(iOS 12, *) {
            if self.networkMonitor == nil {
                self.registerForNetworkChangeNotifications()
            }
        } else {
            // Use Reachability for iOS 11
        }

        // Start refreshing the index
        DispatchQueue.global(qos: .userInitiated).async {
            self.getTotalMessages(userID: userID) {
                self.downloadAndProcessPage(userID: userID){ [weak self] in
                    self?.checkIfIndexingIsComplete(userID: userID, completionHandler: {})
                }
            }
        }
    }

    private func refreshSearchIndex(userID: String) -> Void {
        // Set the state to refresh
        self.setESState(userID: userID, indexingState: .refresh)

        // Initialize Operation Queues for indexing
        self.initializeOperationQueues()

        // Update the UI with refresh state
        self.updateUIWithIndexingStatus(userID: userID)

        // Set processed message to the number of entries in the search index
        userCachedStatus.encryptedSearchProcessedMessages = EncryptedSearchIndexService.shared.getNumberOfEntriesInSearchIndex(for: userID)
        userCachedStatus.encryptedSearchPreviousProcessedMessages = EncryptedSearchIndexService.shared.getNumberOfEntriesInSearchIndex(for: userID)

        // Update last indexed message with the newest message in search index
        userCachedStatus.encryptedSearchLastMessageTimeIndexed = EncryptedSearchIndexService.shared.getOldestMessageInSearchIndex(for: userID).asInt
        userCachedStatus.encryptedSearchLastMessageIDIndexed = EncryptedSearchIndexService.shared.getMessageIDOfOldestMessageInSearchIndex(for: userID)

        // Start refreshing the index
        DispatchQueue.global(qos: .userInitiated).async {
            self.downloadAndProcessPage(userID: userID){ [weak self] in
                self?.checkIfIndexingIsComplete(userID: userID, completionHandler: {})
            }
        }
    }

    private func checkIfIndexingIsComplete(userID: String, completionHandler: @escaping () -> Void) {
        self.getTotalMessages(userID: userID) {
            let numberOfEntriesInSearchIndex: Int = EncryptedSearchIndexService.shared.getNumberOfEntriesInSearchIndex(for: userID)
            print("ES-DEBUG: entries in search index: \(numberOfEntriesInSearchIndex), total messages: \(userCachedStatus.encryptedSearchTotalMessages)")
            if numberOfEntriesInSearchIndex == userCachedStatus.encryptedSearchTotalMessages ||
                self.getESState(userID: userID) == .complete {
                self.setESState(userID: userID, indexingState: .complete)

                // cleanup
                self.cleanUpAfterIndexing(userID: userID)
            }
            completionHandler()
        }
    }

    private func cleanUpAfterIndexing(userID: String) {
        let expectedESStates: [EncryptedSearchIndexState] = [.complete, .partial]
        if expectedESStates.contains(self.getESState(userID: userID)) {
            // set some status variables
            self.viewModel?.isEncryptedSearch = true
            self.viewModel?.currentProgress.value = 100
            self.viewModel?.estimatedTimeRemaining.value = nil
            self.estimateIndexTimeRounds = 0
            self.slowDownIndexBuilding = false

            // Unregister network monitoring
            if #available(iOS 12, *) {
                self.unRegisterForNetworkChangeNotifications()
            } else {
                // Fallback on earlier versions
            }

            // Invalidate timer on same thread as it has been created
            DispatchQueue.main.async {
                self.indexBuildingTimer?.invalidate()
            }

            // Stop background tasks
            #if !APP_EXTENSION
                if #available(iOS 13, *) {
                    self.cancelBGProcessingTask()
                    self.cancelBGAppRefreshTask()
                }
            #endif

            // Send indexing metrics to backend
            var indexingTime: Double = CFAbsoluteTimeGetCurrent() - userCachedStatus.encryptedSearchIndexingStartTime
            if indexingTime.isLess(than: 0.0) {
                print("Error indexing time negative!")
                indexingTime = 0.0
            }
            self.sendIndexingMetrics(indexTime: indexingTime, userID: userID)

            // Compress sqlite database
            //DispatchQueue.main.asyncAfter(deadline: .now() + 3){
            //    EncryptedSearchIndexService.shared.compressSearchIndex(for: userID)
            //}

            // Update UI
            self.updateUIWithIndexingStatus(userID: userID)

            if self.getESState(userID: userID) == .complete {
                // Process events that have been accumulated during indexing
                self.processEventsAfterIndexing(userID: userID) {
                    // Invalidate timer on same thread as it has been created
                    DispatchQueue.main.async {
                        self.indexBuildingTimer?.invalidate()
                    }
                }
            }

            // Update UI
            self.updateUIWithIndexingStatus(userID: userID)
        } else if self.getESState(userID: userID) == .paused {
            // Invalidate timer on same thread as it has been created
            DispatchQueue.main.async {
                self.indexBuildingTimer?.invalidate()
            }
        }
    }

    func pauseAndResumeIndexingByUser(isPause: Bool, userID: String) -> Void {
        if isPause {
            userCachedStatus.encryptedSearchNumberOfPauses += 1
            self.setESState(userID: userID, indexingState: .paused)
        } else {
            self.setESState(userID: userID, indexingState: .downloading)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            self.pauseAndResumeIndexing(userID: userID)
        }
    }

    func pauseAndResumeIndexingDueToInterruption(isPause: Bool, userID: String){
        if isPause {
            userCachedStatus.encryptedSearchNumberOfInterruptions += 1
            self.setESState(userID: userID, indexingState: .paused)
        } else {
            // Check if any of the flags is set to true
            if self.pauseIndexingDueToLowBattery ||
                self.pauseIndexingDueToNetworkConnectivityIssues ||
                self.pauseIndexingDueToOverheating ||
                self.pauseIndexingDueToWiFiNotDetected {
                self.setESState(userID: userID, indexingState: .paused)
                return
            }
            self.setESState(userID: userID, indexingState: .downloading)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            self.pauseAndResumeIndexing(userID: userID)
        }
    }

    private func pauseAndResumeIndexing(userID: String) {
        if self.getESState(userID: userID) == .paused {
            print("Pause indexing!")
            self.deleteAndClearOperationQueues() {
                self.cleanUpAfterIndexing(userID: userID)
                // In case of an interrupt - update UI
                if self.pauseIndexingDueToLowBattery ||
                    self.pauseIndexingDueToNetworkConnectivityIssues ||
                    self.pauseIndexingDueToOverheating ||
                    self.pauseIndexingDueToWiFiNotDetected {
                    self.updateUIWithIndexingStatus(userID: userID)
                }
            }
        } else {
            print("Resume indexing...")
            self.restartIndexBuilding(userID: userID)
        }
    }

    struct MessageAction {
        var action: NSFetchedResultsChangeType? = nil
        var message: Message? = nil
    }

    func updateSearchIndex(action: NSFetchedResultsChangeType, message: Message?, userID: String, completionHandler: @escaping () -> Void) {
        guard self.deletingCacheInProgress == false else {
            completionHandler()
            return
        }

        let expectedESStates: [EncryptedSearchIndexState] = [.downloading, .paused, .background, .backgroundStopped]
        if expectedESStates.contains(self.getESState(userID: userID)) {
            let messageAction: MessageAction = MessageAction(action: action, message: message)
            self.eventsWhileIndexing!.append(messageAction)
            completionHandler()
        } else {
            switch action {
                case .delete, .move:
                    self.updateMessageMetadataInSearchIndex(action: action, message: message, userID: userID) {
                        // Update cache if existing
                        if EncryptedSearchCacheService.shared.isCacheBuilt(userID: userID){
                            let _ = EncryptedSearchCacheService.shared.updateCachedMessage(userID: userID, message: message)
                        }
                        completionHandler()
                    }
                case .insert:
                    self.insertSingleMessageToSearchIndex(message: message, userID: userID) {
                        // Update cache if existing
                        if EncryptedSearchCacheService.shared.isCacheBuilt(userID: userID){
                            let _ = EncryptedSearchCacheService.shared.updateCachedMessage(userID: userID, message: message)
                        }
                        completionHandler()
                    }
            case .update:
                completionHandler()
                break
            default:
                completionHandler()
                return
            }
        }
    }

    private func processEventsAfterIndexing(userID: String, completionHandler: @escaping () -> Void) {
        if self.eventsWhileIndexing!.isEmpty {
            completionHandler()
        } else {
            // Set state to refresh
            self.setESState(userID: userID, indexingState: .refresh)

            if let messageAction: MessageAction = self.eventsWhileIndexing?.removeFirst() {
                self.updateSearchIndex(action: messageAction.action!, message: messageAction.message, userID: userID, completionHandler: {})
            }
            self.processEventsAfterIndexing(userID: userID) {
                print("All events processed that have been accumulated during indexing...")

                // Set state to complete when finished
                self.setESState(userID: userID, indexingState: .complete)

                // Update UI
                self.updateUIWithIndexingStatus(userID: userID)
            }
        }
    }

    func insertSingleMessageToSearchIndex(message: Message?, userID: String, completionHandler: @escaping () -> Void) {
        guard let messageToInsert = message else {
            completionHandler()
            return
        }
        // Just insert a new message if the search index exists for the user - otherwise it needs to be build first
        if EncryptedSearchIndexService.shared.checkIfSearchIndexExists(for: userID) {
            let esMessage:ESMessage? = self.convertMessageToESMessage(for: messageToInsert)
            self.updateUserAndAPIServices() // ensure that the current user's API service is used for the requests
            self.fetchMessageDetailForMessage(userID: userID, message: esMessage!) { [weak self] (error, messageWithDetails) in
                if error == nil {
                    self?.decryptAndExtractDataSingleMessage(for: messageWithDetails!, userID: userID) {
                        userCachedStatus.encryptedSearchProcessedMessages += 1
                        userCachedStatus.encryptedSearchLastMessageTimeIndexed = Int((messageWithDetails!.Time))
                        userCachedStatus.encryptedSearchLastMessageIDIndexed = messageWithDetails!.ID
                        completionHandler()
                    }
                } else {
                    print("Error: Cannot fetch message details for message.")
                    completionHandler()
                }
            }
        } else {
            print("Error: No search index found for user: \(userID)")
            completionHandler()
        }
    }

    func deleteMessageFromSearchIndex(message: Message?, userID: String, completionHandler: @escaping () -> Void) {
        guard let messageToDelete = message else {
            completionHandler()
            return
        }

        // Just delete a message if the search index exists for the user - otherwise it needs to be build first
        if EncryptedSearchIndexService.shared.checkIfSearchIndexExists(for: userID) {
            let _ = EncryptedSearchIndexService.shared.removeEntryFromSearchIndex(user: userID, message: messageToDelete.messageID)
            // delete message from cache if cache is built
            if EncryptedSearchCacheService.shared.isCacheBuilt(userID: userID){
                let _ = EncryptedSearchCacheService.shared.deleteCachedMessage(userID: userID, messageID: messageToDelete.messageID)
            }
            completionHandler()
        } else {
            print("Error: No search index found for user: \(userID)")
            completionHandler()
        }
    }

    func deleteSearchIndex(userID: String, completionHandler: @escaping () -> Void) {
        // Run on a seperate thread to avoid blocking the main thread
        DispatchQueue.global(qos: .userInteractive).async {
            // Update state
            self.setESState(userID: userID, indexingState: .disabled)
            userCachedStatus.isEncryptedSearchOn = false

            // Cancle any running indexing process
            self.deleteAndClearOperationQueues() {
                // update user cached status
                userCachedStatus.encryptedSearchTotalMessages = 0
                userCachedStatus.encryptedSearchLastMessageTimeIndexed = 0
                userCachedStatus.encryptedSearchLastMessageIDIndexed = nil
                userCachedStatus.encryptedSearchProcessedMessages = 0
                userCachedStatus.encryptedSearchPreviousProcessedMessages = 0
            }

            userCachedStatus.encryptedSearchNumberOfPauses = 0
            userCachedStatus.encryptedSearchNumberOfInterruptions = 0

            // Just delete the search index if it exists
            var isIndexSuccessfullyDelete: Bool = false
            if EncryptedSearchIndexService.shared.checkIfSearchIndexExists(for: userID) {
                isIndexSuccessfullyDelete = EncryptedSearchIndexService.shared.deleteSearchIndex(for: userID)
            }

            // Update some variables
            self.eventsWhileIndexing = []

            self.pauseIndexingDueToNetworkConnectivityIssues = false
            self.pauseIndexingDueToWiFiNotDetected = false
            self.pauseIndexingDueToOverheating = false
            self.pauseIndexingDueToLowBattery = false
            self.estimateIndexTimeRounds = 0
            self.slowDownIndexBuilding = false

            // Reset view model
            self.viewModel?.isEncryptedSearch = false
            self.viewModel?.progressedMessages.value = 0
            self.viewModel?.currentProgress.value = 0
            self.viewModel?.isIndexingComplete.value = false
            self.viewModel?.interruptStatus.value = nil
            self.viewModel?.interruptAdvice.value = nil
            self.viewModel?.estimatedTimeRemaining.value = nil
            self.viewModel = nil
            #if !APP_EXTENSION
                self.searchViewModel = nil
            #endif

            // Invalidate timer on same thread as it has been created
            DispatchQueue.main.async {
                self.indexBuildingTimer?.invalidate()
            }

            // Stop background tasks
            #if !APP_EXTENSION
                self.endBackgroundTask()
            #endif
            if #available(iOS 13.0, *) {
                self.cancelBGProcessingTask()
                self.cancelBGAppRefreshTask()
            }

            // Unregister network monitoring
            if #available(iOS 12, *) {
                self.unRegisterForNetworkChangeNotifications()
            } else {
                // Fallback on earlier versions
            }

            // Update UI
            self.updateUIWithIndexingStatus(userID: userID)

            if isIndexSuccessfullyDelete {
                print("Search index for user \(userID) sucessfully deleted!")
            } else {
                print("Error when deleting the search index!")
            }
            completionHandler()
        }
    }

    private func updateMessageMetadataInSearchIndex(action: NSFetchedResultsChangeType, message: Message?, userID: String, completionHandler: @escaping () -> Void) {
        guard let messageToUpdate = message else {
            completionHandler()
            return
        }
        if EncryptedSearchIndexService.shared.checkIfSearchIndexExists(for: userID){
            self.deleteMessageFromSearchIndex(message: messageToUpdate, userID: userID) {
                // Wait until delete is done - then insert updated message
                self.insertSingleMessageToSearchIndex(message: messageToUpdate, userID: userID) {
                    completionHandler()
                }
            }
        } else {
            print("Error: No search index found for user: \(userID)")
            completionHandler()
        }
    }

    private func updateUserAndAPIServices() -> Void {
        let usersManager: UsersManager = sharedServices.get(by: UsersManager.self)
        let user: UserManager? = usersManager.firstUser
        self.messageService = user?.messageService
        self.apiService = user?.apiService
        self.userDataSource = self.messageService?.userDataSource
    }

    // Checks the total number of messages on the backend
    func getTotalMessages(userID: String, completionHandler: @escaping () -> Void) -> Void {
        self.updateUserAndAPIServices()     // ensure that the current user's API service is used for the requests
        let request = FetchMessagesByLabel(labelID: Message.Location.allmail.rawValue, endTime: 0, isUnread: false)
        self.apiService?.GET(request){ (_, responseDict, error) in
            if error != nil {
                print("Error for api get number of messages: \(String(describing: error))")
            } else if let response = responseDict {
                userCachedStatus.encryptedSearchTotalMessages = response["Total"] as! Int
            } else {
                print("Unable to parse response: \(NSError.unableToParseResponse(responseDict))")
            }
            completionHandler()
        }
    }

    func convertMessageToESMessage(for message: Message) -> ESMessage {
        let decoder = JSONDecoder()

        let jsonSenderData: Data = Data(message.sender?.utf8 ?? "".utf8)
        var sender: ESSender? = ESSender(Name: "", Address: "")
        do {
            sender = try decoder.decode(ESSender.self, from: jsonSenderData)
        } catch {
            print("Error when decoding message.sender")
        }

        let senderAddress: String = sender?.Address ?? ""
        let senderName: String = sender?.Name ?? ""

        var toList: [ESSender?] = []
        var ccList: [ESSender?] = []
        var bccList: [ESSender?] = []
        let jsonToListData: Data = message.toList.data(using: .utf8)!
        let jsonCCListData: Data = message.ccList.data(using: .utf8)!
        let jsonBCCListData: Data = message.bccList.data(using: .utf8)!

        do {
            toList = try decoder.decode([ESSender].self, from: jsonToListData)
            ccList = try decoder.decode([ESSender].self, from: jsonCCListData)
            bccList = try decoder.decode([ESSender].self, from: jsonBCCListData)
        } catch {
            print("Error when decoding message.tolist, ccList or bccList")
        }

        let isReplied: Int = message.replied ? 1 : 0
        let isRepliedAll: Int = message.repliedAll ? 1 : 0
        let isForwarded: Int = message.forwarded ? 1 : 0
        var labelIDs: Set<String> = Set()
        message.labels.forEach { label in
            labelIDs.insert((label as! Label).labelID)
        }
        let externalID: String = ""
        let unread: Int = message.unRead ? 1 : 0
        let time: Double = message.time!.timeIntervalSince1970
        let isEncrypted: Int = message.isE2E ? 1 : 0

        let newESMessage = ESMessage(id: message.messageID, order: Int(truncating: message.order), conversationID: message.conversationID, subject: message.subject, unread: unread, type: Int(truncating: message.messageType), senderAddress: senderAddress, senderName: senderName, sender: sender!, toList: toList, ccList: ccList, bccList: bccList, time: time, size: Int(truncating: message.size), isEncrypted: isEncrypted, expirationTime: message.expirationTime, isReplied: isReplied, isRepliedAll: isRepliedAll, isForwarded: isForwarded, spamScore: Int(truncating: message.spamScore), addressID: message.addressID, numAttachments: Int(truncating: message.numAttachments), flags: Int(truncating: message.flags), labelIDs: labelIDs, externalID: externalID, body: message.body, header: message.header, mimeType: message.mimeType, userID: message.userID)
        newESMessage.isStarred = message.starred
        return newESMessage
    }

    private func jsonStringToESMessage(jsonData: Data) throws -> ESMessage? {
        let decoder = JSONDecoder()
        let message: ESMessage? = try decoder.decode(ESMessage.self, from: jsonData)
        return message
    }

    private func parseMessageResponse(userID: String, labelID: String, isUnread:Bool, response: [String:Any], completion: ((Error?, [ESMessage]?) -> Void)?) -> Void {
        guard var messagesArray = response["Messages"] as? [[String: Any]] else {
            completion?(NSError.unableToParseResponse(response), nil)
            return
        }

        for (index, _) in messagesArray.enumerated() {
            messagesArray[index]["UserID"] = userID
        }

        do {
            var messages: [ESMessage] = []
            for (index, _) in messagesArray.enumerated() {
                let jsonDict = messagesArray[index]
                let jsonData = try JSONSerialization.data(withJSONObject: jsonDict, options: [])
                
                let message: ESMessage? = try self.jsonStringToESMessage(jsonData: jsonData)
                message?.isDetailsDownloaded = false
                messages.append(message!)
            }
            completion?(nil, messages)
        } catch {
            print("error: \(error)")
            completion?(error, nil)
        }
    }

    private func parseMessageDetailResponse(userID: String, response: [String: Any], completion: ((Error?, ESMessage?)-> Void)?) -> Void {
        guard var msg = response["Message"] as? [String: Any] else {
            completion?(NSError.unableToParseResponse(response), nil)
            return
        }

        msg.removeValue(forKey: "Location")
        msg.removeValue(forKey: "Starred")
        msg.removeValue(forKey: "test")
        msg["UserID"] = userID

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: msg, options: [])
            let message: ESMessage? = try self.jsonStringToESMessage(jsonData: jsonData)

            message?.isDetailsDownloaded = true
            message?.isStarred = false

            completion?(nil, message)
        } catch {
            print("error when serialization: \(error)")
            completion?(error, nil)
        }
    }

    private func fetchSingleMessageFromServer(byMessageID messageID: String, completionHandler: ((Error?) -> Void)?) -> Void {
        self.updateUserAndAPIServices() // ensure that the current user's API service is used for the requests
        let request = FetchMessagesByID(msgIDs: [messageID])
        self.apiService?.GET(request) { [weak self] (task, responseDict, error) in
            if error != nil {
                DispatchQueue.main.async {
                    completionHandler?(error)
                }
            } else if let response = responseDict {
                self?.messageService?.cacheService.parseMessagesResponse(labelID: Message.Location.allmail.rawValue, isUnread: false, response: response) { (errorFromParsing) in
                    if let err = errorFromParsing {
                        DispatchQueue.main.async {
                            completionHandler?(err as NSError)
                        }
                    } else {
                        DispatchQueue.main.async {
                            completionHandler?(nil)
                        }
                    }
                }
            } else {
                DispatchQueue.main.async {
                    completionHandler?(NSError.unableToParseResponse(responseDict))
                }
            }
        }
    }

    public func fetchMessages(userID: String, byLabel labelID: String, time: Int, lastMessageID: String?, completionHandler: ((Error?, [ESMessage]?) -> Void)?) -> Void {
        let request = FetchMessagesByLabel(labelID: labelID, endTime: time, isUnread: false, pageSize: self.pageSize, endID: lastMessageID)
        self.apiService?.GET(request, priority: "u=7"){ [weak self] (task, responseDict, error) in
            if error != nil {
                DispatchQueue.main.async {
                    completionHandler?(error, nil)
                }
            } else if let response = responseDict {
                self?.parseMessageResponse(userID: userID, labelID: labelID, isUnread: false, response: response){ errorFromParsing, messages in
                    if let err = errorFromParsing {
                        DispatchQueue.main.async {
                            completionHandler?(err as NSError, nil)
                        }
                    } else {
                        //everything went well - return messages
                        DispatchQueue.main.async {
                            completionHandler?(error, messages)
                        }
                    }
                }
            } else {
                DispatchQueue.main.async {
                    completionHandler?(NSError.unableToParseResponse(responseDict), nil)
                }
            }
        }
    }

    private func fetchMessageDetailForMessage(userID: String, message: ESMessage, completionHandler: ((Error?, ESMessage?) -> Void)?){
        if message.isDetailsDownloaded! {
            DispatchQueue.main.async {
                completionHandler?(nil, message)
            }
        } else {
            self.apiService?.messageDetail(messageID: message.ID, priority: "u=7"){ [weak self] (task, responseDict, error) in
                if error != nil {
                    // 429 - too many requests - retry after some time
                    let urlResponse: HTTPURLResponse? = task?.response as? HTTPURLResponse
                    if urlResponse?.statusCode == 429 {
                        let headers: [String: Any]? = urlResponse?.allHeaderFields as? [String: Any]
                        let timeOut: String? = headers?["retry-after"] as? String
                        if let retryTime = timeOut {
                            DispatchQueue.main.asyncAfter(deadline: .now() + Double(retryTime)!){
                                print("Error 429: Retry fetch after \(timeOut!) seconds for message: \(message.ID)")
                                self?.fetchMessageDetailForMessage(userID: userID, message: message){ err, msg in
                                    completionHandler?(err, msg)
                                }
                            }
                        } else {
                            // Retry-after header not present, return error
                            DispatchQueue.main.async {
                                completionHandler?(error, nil)
                            }
                        }
                    } else {
                        DispatchQueue.main.async {
                            completionHandler?(error, nil)
                        }
                    }
                } else if let response = responseDict {
                    self?.parseMessageDetailResponse(userID: userID, response: response) { (errorFromParsing, msg) in
                        if let err = errorFromParsing {
                            DispatchQueue.main.async {
                                completionHandler?(err as NSError, nil)
                            }
                        } else {
                            // everything went well - return messages
                            DispatchQueue.main.async {
                                completionHandler?(error, msg)
                            }
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        completionHandler?(NSError.unableToParseResponse(responseDict), nil)
                    }
                }
            }
        }
    }

    private func downloadAndProcessPage(userID: String, completionHandler: @escaping () -> Void) -> Void {
        let group = DispatchGroup()
        group.enter()
        if self.addTimeOutWhenIndexingAsMemoryExceeds {
            print("ES-MEMORY: memory exceeded. Put indexing thread to sleep for 2 seconds...")
            // Sleep thread for 2 seconds - then re-check if memory is below 10%
            Thread.sleep(forTimeInterval: 2)
        }
        self.downloadPage(userID: userID) {
            print("Processed messages: \(userCachedStatus.encryptedSearchProcessedMessages), total messages: \(userCachedStatus.encryptedSearchTotalMessages)")
            group.leave()
        }

        group.notify(queue: .main) {
            if userCachedStatus.encryptedSearchProcessedMessages >= userCachedStatus.encryptedSearchTotalMessages {
                // temporary fix - if there are more messages processed then total messages set to complete
                // this fixes the issue of lost messages during indexing
                self.setESState(userID: userID, indexingState: .complete)
                completionHandler()
            } else {
                let expectedESStates: [EncryptedSearchIndexState] = [.downloading, .background, .refresh]
                if expectedESStates.contains(self.getESState(userID: userID)) {
                    // Recursion
                    self.downloadAndProcessPage(userID: userID){
                        completionHandler()
                    }
                } else {
                    // Index building stopped from outside - finish up current page and return
                    return
                }
            }
        }
    }

    private func downloadPage(userID: String, completionHandler: @escaping () -> Void) {
        // Start a new thread to download page
        DispatchQueue.global(qos: .userInitiated).async {
            var processPageOperation: Operation? = DownloadPageAsyncOperation(userID: userID)
            if let operation = processPageOperation {
                if let downloadPageQueue = self.downloadPageQueue {
                    // Adapt indexing speed due to RAM usage
                    self.adaptIndexingSpeed()
                    downloadPageQueue.maxConcurrentOperationCount = self.downloadPageQueue?.maxConcurrentOperationCount ?? 1
                    downloadPageQueue.addOperation(operation)
                    downloadPageQueue.waitUntilAllOperationsAreFinished()
                } else {
                    print("Error - download page queue is nil")
                }
            }
            processPageOperation = nil
            completionHandler()
        }
    }

    func processPageOneByOne(forBatch messages: [ESMessage]?, userID: String, completionHandler: @escaping () -> Void) -> Void {
        if let messages = messages {
            // If there are no messages to process, return
            guard messages.count > 0 else {
                completionHandler()
                return
            }

            // Start a new thread to process the page
            DispatchQueue.global(qos: .userInitiated).async {
                if let messageIndexingQueue = self.messageIndexingQueue {
                    for m in messages {
                        var processMessageOperation: Operation? = IndexSingleMessageAsyncOperation(m, userID)
                        if let operation = processMessageOperation {
                            messageIndexingQueue.maxConcurrentOperationCount = self.indexingSpeed
                            messageIndexingQueue.addOperation(operation)
                        }
                        processMessageOperation = nil    // Clean up
                    }
                    messageIndexingQueue.waitUntilAllOperationsAreFinished()
                } else {
                    print("Error - message indexing queue is nil")
                }
                completionHandler()
            }
        } else {
            completionHandler()
            return
        }
    }

    func getMessageDetailsForSingleMessage(for message: ESMessage, userID: String, completionHandler: @escaping (ESMessage?) -> Void) -> Void {
        if message.isDetailsDownloaded! {
            completionHandler(message)
        } else {
            self.fetchMessageDetailForMessage(userID: userID, message: message) { error, msg in
                if error == nil {
                    completionHandler(msg)
                } else {
                    print("Error when fetching message details: \(String(describing: error))")
                }
            }
        }
    }

    private func getMessage(messageID: String, completionHandler: @escaping (Message?) -> Void) -> Void {
        let fetchedResultsController = self.messageService?.fetchedMessageControllerForID(messageID)

        if let fetchedResultsController = fetchedResultsController {
            do {
                try fetchedResultsController.performFetch()
            } catch let ex as NSError {
                print(" error: \(ex)")
            }
        }

        if let context = fetchedResultsController?.managedObjectContext{
            if let message = Message.messageForMessageID(messageID, inManagedObjectContext: context) {
                completionHandler(message)
            } else {
                completionHandler(nil)
            }
        } else {
            completionHandler(nil)
        }
    }

    func decryptBody(message: ESMessage) throws -> String? {
        let addressKeys = self.getAddressKeys(for: message.AddressID)
        if addressKeys.isEmpty {
            return message.Body
        }
        
        guard let dataSource = self.userDataSource,
              case let passphrase = dataSource.mailboxPassword,
              var body = try self.decryptBody(message: message,
                                              addressKeys: addressKeys,
                                              privateKeys: dataSource.userPrivateKeys,
                                              passphrase: passphrase,
                                              newScheme: dataSource.newSchema) else {
                  throw Crypto.CryptoError.decryptionFailed
        }

        if message.isPgpMime! || message.isSignedMime! {
            let result = self.postProcessMIME(body: body)
            body = result.0
            //message.tempAtts = result.1   //TODO
            return body
        } else if message.isPgpInline {
            let result = self.postProcessPGPInline(
                isPlainText: message.isPlainText,
                isMultipartMixed: message.isMultipartMixed,
                body: body)
            body = result.0
            //message.tempAtts = result.1   //TODO
            return body
        }
        if message.isPlainText {
            if message.draft {
                return body
            } else {
                body = body.encodeHtml()
                return body.ln2br()
            }
        }

        return body
    }
    
    // MessageDecrypted.swift: 112
    func decryptBody(message: ESMessage,
                     addressKeys: [Key],
                     privateKeys: [Data],
                     passphrase: String,
                     newScheme: Bool) throws -> String? {

        var body: String?
        if newScheme {
            body = try message.decryptBody(keys: addressKeys,
                                           userKeys: privateKeys,
                                           passphrase: passphrase)
        } else {
            body = try message.decryptBody(keys: addressKeys,
                                           passphrase: passphrase)
        }
        return body
    }
    
    // MessageDecrypted.swift: 184
    func postProcessPGPInline(isPlainText: Bool,
                              isMultipartMixed: Bool,
                              body: String) -> (String, [MimeAttachment]) {
        var body = body
        if isPlainText {
            let head = "<html><head></head><body>"
            // The plain text draft from android and web doesn't have
            // the head, so if the draft contains head
            // It means the draft already encoded
            if !body.hasPrefix(head) {
                body = body.encodeHtml()
                body = body.ln2br()
            }
            return (body, [])
        } else if isMultipartMixed {
            return self.postProcessMIME(body: body)
        }
        return (body, [])
    }
    
    // MessageDecrypter.swift: 130
    func postProcessMIME(body: String) -> (String, [MimeAttachment])  {
        guard let mimeMessage = MIMEMessage(string: body) else {
            return (body.multipartGetHtmlContent(), [])
        }
        var body = body
        if let html = mimeMessage.mainPart.part(ofType: Message.MimeType.html)?.bodyString {
            body = html
        } else if let text = mimeMessage.mainPart.part(ofType: Message.MimeType.plainText)?.bodyString {
            body = text.encodeHtml()
            body = "<html><body>\(body.ln2br())</body></html>"
        }

        let (mimeAttachments, mimeBody) = self.parse(mimeMessage: mimeMessage, body: body)
        body = mimeBody
        return (body, mimeAttachments)
    }
    
    // MessageDecrypted.swift: 147
    func parse(mimeMessage: MIMEMessage, body: String) -> ([MimeAttachment], String) {
        var body = body
        let mimeAttachments = mimeMessage.mainPart.findAtts()
        var infos = [MimeAttachment]()
        for attachment in mimeAttachments {
            // Replace inline data
            if var contentID = attachment.cid,
               let rawBody = attachment.rawBodyString {
                contentID = contentID.preg_replace("<", replaceto: "")
                contentID = contentID.preg_replace(">", replaceto: "")
                let type = "image/jpg" //cidPart.headers[.contentType]?.body ?? "image/jpg;name=\"unknown.jpg\""
                let encode = attachment.headers[.contentTransferEncoding]?.body ?? "base64"
                body = body.preg_replace_none_regex("src=\"cid:\(contentID)\"", replaceto: "src=\"data:\(type);\(encode),\(rawBody)\"")
            }

            guard let filename = attachment.getFilename()?.clear else {
                continue
            }
            let data = attachment.data
            let path = FileManager.default
                .attachmentDirectory.appendingPathComponent(filename)
            do {
                try data.write(to: path, options: [.atomic])
            } catch {
                continue
            }
            let disposition = attachment.contentDisposition?.raw ?? ""
            let mimeAttachment = MimeAttachment(filename: filename,
                                                size: data.count,
                                                mime: filename.mimeType(),
                                                path: path,
                                                disposition: disposition)
            infos.append(mimeAttachment)
        }
        return (infos, body)
    }

    // MessageDecrypter.swift:103 TODO
    func getAddressKeys(for addressID: String?) -> [Key] {
        guard let addressID = addressID,
              let keys = self.userDataSource?
                .getAllAddressKey(address_id: addressID) else {
            return self.userDataSource?.addressKeys ?? []
        }
        return keys
    }

    func decryptAndExtractDataSingleMessage(for message: ESMessage, userID: String,  completionHandler: @escaping () -> Void) -> Void {
        var body: String? = ""
        do {
            body = try self.decryptBody(message: message)
        } catch {
            print("Error when decrypting messages: \(error).")
        }

        var emailContent: String? = EmailparserExtractData(body!, true)
        body = nil
        var encryptedContent: EncryptedsearchEncryptedMessageContent? = self.createEncryptedContent(message: message, cleanedBody: emailContent!, userID: userID)
        emailContent = nil

        // add message to search index db
        self.addMessageToSearchIndex(userID: userID, message: message, encryptedContent: encryptedContent) {
            encryptedContent = nil
            completionHandler()
        }
    }

    func createEncryptedContent(message: ESMessage, cleanedBody: String, userID: String) -> EncryptedsearchEncryptedMessageContent? {
        let sender: EncryptedsearchRecipient? = EncryptedsearchRecipient(message.Sender.Name, email: message.Sender.Address)
        let toList: EncryptedsearchRecipientList = EncryptedsearchRecipientList()
        message.ToList.forEach { s in
            let r: EncryptedsearchRecipient? = EncryptedsearchRecipient(s!.Name, email: s!.Address)
            toList.add(r)
        }
        let ccList: EncryptedsearchRecipientList = EncryptedsearchRecipientList()
        message.CCList.forEach { s in
            let r: EncryptedsearchRecipient? = EncryptedsearchRecipient(s!.Name, email: s!.Address)
            ccList.add(r)
        }
        let bccList: EncryptedsearchRecipientList = EncryptedsearchRecipientList()
        message.BCCList.forEach { s in
            let r: EncryptedsearchRecipient? = EncryptedsearchRecipient(s!.Name, email: s!.Address)
            bccList.add(r)
        }
        let decryptedMessageContent: EncryptedsearchDecryptedMessageContent? = EncryptedsearchNewDecryptedMessageContent(message.Subject,
                                                                                                                         sender,
                                                                                                                         cleanedBody,
                                                                                                                         toList,
                                                                                                                         ccList,
                                                                                                                         bccList,
                                                                                                                         message.AddressID,
                                                                                                                         message.ConversationID,
                                                                                                                         Int64(message.Flags),
                                                                                                                         message.Unread == 1,
                                                                                                                         message.isStarred ?? false,
                                                                                                                         message.IsReplied == 1,
                                                                                                                         message.IsRepliedAll == 1,
                                                                                                                         message.IsForwarded == 1,
                                                                                                                         message.NumAttachments,
                                                                                                                         Int64(message.ExpirationTime?.timeIntervalSince1970 ?? 0))

        let cipher: EncryptedsearchAESGCMCipher? = self.getCipher(userID: userID)
        var encryptedMessageContent: EncryptedsearchEncryptedMessageContent? = nil

        do {
            encryptedMessageContent = try cipher?.encrypt(decryptedMessageContent)
        } catch {
            print(error)
        }

        return encryptedMessageContent
    }

    private func getCipher(userID: String) -> EncryptedsearchAESGCMCipher? {
        var cipher: EncryptedsearchAESGCMCipher? = nil
        let key: Data? = self.retrieveSearchIndexKey(userID: userID)
        if let key = key {
            cipher = EncryptedsearchAESGCMCipher(key)
        } else {
            print("Error: Search index key cannot be generated!")
        }
        return cipher
    }

    private func retrieveSearchIndexKey(userID: String) -> Data? {
        var key: Data? = KeychainWrapper.keychain.data(forKey: "searchIndexKey_" + userID)
        // Check if user already has an key - otherwise generate one
        if key == nil {
            key = self.generateSearchIndexKey(userID: userID)
        }
        return key
    }

    private func generateSearchIndexKey(userID: String) -> Data? {
        let keylen: Int = 32
        var error: NSError?
        let bytes: Data? = CryptoRandomToken(keylen, &error)

        if let key = bytes {
            // Add search index key to KeyChain
            KeychainWrapper.keychain.set(key, forKey: "searchIndexKey_" + userID)
            return key
        } else {
            print("Error when generating search index key!")
            return nil
        }
    }

    func addMessageToSearchIndex(userID: String,
                                 message: ESMessage,
                                 encryptedContent: EncryptedsearchEncryptedMessageContent?,
                                 completionHandler: @escaping () -> Void) -> Void {
        let ciphertext: String? = encryptedContent?.ciphertext
        let encryptedContentSize: Int = ciphertext?.count ?? 0

        if self.checkIfStorageLimitIsExceeded(userID: userID) == true {
            // Shrink search index to fit message
            let sizeOfIndex: Int64? = EncryptedSearchIndexService.shared.getSizeOfSearchIndex(for: userID).asInt64
            if let sizeOfIndex = sizeOfIndex {
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = EncryptedSearchIndexService.shared.shrinkSearchIndex(userID: userID, expectedSize: sizeOfIndex - Int64(encryptedContentSize))
                }
            }
        }

        if self.checkIfEnoughStorage(userID: userID) == false {
            // Shrink search index to fit message
            let sizeOfIndex: Int64? = EncryptedSearchIndexService.shared.getSizeOfSearchIndex(for: userID).asInt64
            if let sizeOfIndex = sizeOfIndex {
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = EncryptedSearchIndexService.shared.shrinkSearchIndex(userID: userID, expectedSize: sizeOfIndex - Int64(encryptedContentSize))
                }
            }
        }

        let rowID = EncryptedSearchIndexService.shared.addNewEntryToSearchIndex(userID: userID, messageID: message.ID, time: Int(message.Time), order: message.Order, labelIDs: message.LabelIDs, encryptionIV: encryptedContent?.iv, encryptedContent: ciphertext, encryptedContentFile: "", encryptedContentSize: encryptedContentSize)
        if rowID == -1 {
            print("Error: message \(message.ID) couldn't be inserted to search index.")
        }

        completionHandler()
    }

    // MARK: - Search Functions
    #if !APP_EXTENSION
    func search(userID: String, query: String, page: Int, searchViewModel: SearchViewModel, completion: ((NSError?, Int?) -> Void)?) {
        print("Encrypted Search: query: \(query), page: \(page)")

        if query == "" {
            completion?(nil, nil) // There are no results for an empty search query
        }

        // Save query - needed for highlighting
        self.searchQuery = self.processSearchKeywords(query: query)

        // Update API services to current user
        self.updateUserAndAPIServices()

        // Set the viewmodel
        self.searchViewModel = searchViewModel

        // Check if this is the first search
        self.isFirstSearch = self.hasSearchedBefore(userID: userID)

        // Start timing search
        let startSearch: Double = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.async {
            self.slowSearchTimer = Timer.scheduledTimer(timeInterval: 5,
                                                        target: self,
                                                        selector: #selector(self.reactToSlowSearch),
                                                        userInfo: nil,
                                                        repeats: false)
        }

        // Initialize searcher, cipher
        let searcher: EncryptedsearchSimpleSearcher = self.getSearcher(query: self.searchQuery)
        let cipher: EncryptedsearchAESGCMCipher? = self.getCipher(userID: userID)
        guard let cipher = cipher else {
            print("Error when searching: cipher for search index is nil.")
            return
        }

        // Create new search state if not already existing
        if self.searchState == nil {
            self.searchState = EncryptedsearchSearchState()
        }

        // Build the cache
        var numberOfResultsFoundByCachedSearch: Int = 0
        let cache: EncryptedsearchCache? = self.getCache(cipher: cipher, userID: userID)
        if let cache = cache {
            print("Number of messages in cache: \(cache.getLength())")

            // Do cache search first
            numberOfResultsFoundByCachedSearch = self.doCachedSearch(searcher: searcher,
                                                                     cache: cache,
                                                                     searchViewModel: searchViewModel,
                                                                     page: page,
                                                                     userID: userID)
            self.numberOfResultsFoundBySearch += numberOfResultsFoundByCachedSearch
            print("Results found by cache search: ", numberOfResultsFoundByCachedSearch)
        }

        // Do index search next - unless search is already completed
        if self.searchState!.cachedSearchDone &&
            !self.searchState!.isComplete &&
            numberOfResultsFoundByCachedSearch <= self.searchResultPageSize {
            self.numberOfResultsFoundBySearch = self.doIndexSearch(searcher: searcher,
                                                                   cipher: cipher,
                                                                   userID: userID,
                                                                   searchViewModel: searchViewModel,
                                                                   page: page,
                                                                   numberOfResultsFoundByCachedSearch: numberOfResultsFoundByCachedSearch)
            print("Results found by index search: ", self.numberOfResultsFoundBySearch - numberOfResultsFoundByCachedSearch)
        }

        // Do timings for entire search procedure
        let endSearch: Double = CFAbsoluteTimeGetCurrent()
        print("Search finished. Time: \(endSearch-startSearch)")

        // Search finished - clean up
        self.isSearching = false
        // Invalidate timer on same thread as it has been created
        DispatchQueue.main.async {
            self.slowSearchTimer?.invalidate()
        }

        // Send some search metrics
        self.sendSearchMetrics(searchTime: endSearch-startSearch, cache: cache, userID: userID)

        // Call completion handler
        completion?(nil, self.numberOfResultsFoundBySearch)
    }
    #endif

    private func processSearchKeywords(query: String) -> [String] {
        let trimmedLowerCase = query.trim().localizedLowercase
        let correctQuotes: String = self.findAndReplaceDoubleQuotes(query: trimmedLowerCase)
        let keywords: [String] = self.extractKeywords(query: correctQuotes)
        return keywords
    }

    private func extractKeywords(query: String) -> [String] {
        guard query.contains(check: "\"") else {
            return query.components(separatedBy: " ")
        }

        var keywords: [String] = query.components(separatedBy: "\"")
        keywords.forEach { keyword in
            if keyword == "" {  // remove keyword if its empty
                if let index = keywords.firstIndex(of: keyword) {
                    keywords.remove(at: index)
                }
            }
        }
        return keywords
    }

    private func findAndReplaceDoubleQuotes(query: String) -> String {
        var queryNormalQuotes = query.replacingOccurrences(of: "\u{201C}", with: "\"")  // left double quotes
        queryNormalQuotes = queryNormalQuotes.replacingOccurrences(of: "\u{201D}", with: "\"") // right double quotes
        return queryNormalQuotes
    }

    #if !APP_EXTENSION
    @objc private func reactToSlowSearch() -> Void {
        self.searchViewModel?.slowSearch = true
    }
    #endif

    private func hasSearchedBefore(userID: String) -> Bool {
        let cachedUserID: String? = EncryptedSearchCacheService.shared.getLastCacheUserID()
        if let cachedUserID = cachedUserID {
            if cachedUserID == userID {
                return true
            }
        }
        return false
    }

    func clearSearchState() {
        self.searchState = nil
    }

    private func getSearcher(query: [String]) -> EncryptedsearchSimpleSearcher {
        let contextSize: CLong = 100 // The max size of the content showed in the preview
        let keywords: EncryptedsearchStringList? = self.createEncryptedSearchStringList(query: query)
        return EncryptedsearchSimpleSearcher(keywords, contextSize: contextSize)!
    }

    private func createEncryptedSearchStringList(query: [String]) -> EncryptedsearchStringList? {
        let result: EncryptedsearchStringList? = EncryptedsearchStringList()
        query.forEach { q in
            result?.add(q)
        }
        return result
    }

    private func getCache(cipher: EncryptedsearchAESGCMCipher, userID: String) -> EncryptedsearchCache {
        let dbParams: EncryptedsearchDBParams = EncryptedSearchIndexService.shared.getDBParams(userID)
        let cache: EncryptedsearchCache = EncryptedSearchCacheService.shared.buildCacheForUser(userId: userID, dbParams: dbParams, cipher: cipher)
        return cache
    }

    private func extractSearchResults(userID: String,
                                      searchResults: EncryptedsearchResultList,
                                      completionHandler: @escaping ([Message]?) -> Void) -> Void {
        if searchResults.length() == 0 {
            completionHandler([])
        } else {
            var messages: [Message] = []
            let group = DispatchGroup()

            for index in 0...(searchResults.length()-1) {
                group.enter()
                let result: EncryptedsearchSearchResult? = searchResults.get(index)
                let id: String = (result?.message!.id_)!    //TODO remove force unwrapping
                self.getMessage(messageID: id) { message in
                    if message == nil {
                        // Check if internet is available
                        if self.isInternetConnection() {
                            // Fetch missing messages from server
                            self.fetchSingleMessageFromServer(byMessageID: id) { [weak self] (error) in
                                if error != nil {
                                    print("Error when fetching message details from server. Create message from search index.")
                                    let messageFromSearchIndex: Message? = self?.createMessageFromPreview(userID: userID, searchResult: result)
                                    messages.append(messageFromSearchIndex!)
                                    group.leave()
                                } else {
                                    self?.getMessage(messageID: id) { msg in
                                        if let msg = msg {
                                            messages.append(msg)
                                        } else {
                                            print("Error when fetching message from coredata. Message nil.")
                                        }
                                        group.leave()
                                    }
                                }
                            }
                        } else {
                            // No internet connection available - build message from encrypted search index
                            let messageFromSearchIndex: Message = self.createMessageFromPreview(userID: userID, searchResult: result)
                            messages.append(messageFromSearchIndex)
                            group.leave()
                        }
                    } else {
                        messages.append(message!)
                        group.leave()
                    }
                }
            }

            group.notify(queue: .main){
                completionHandler(messages)
            }
        }
    }

    #if !APP_EXTENSION
    private func doIndexSearch(searcher: EncryptedsearchSimpleSearcher,
                               cipher: EncryptedsearchAESGCMCipher,
                               userID: String,
                               searchViewModel: SearchViewModel,
                               page: Int,
                               numberOfResultsFoundByCachedSearch: Int) -> Int {
        let startIndexSearch: Double = CFAbsoluteTimeGetCurrent()
        let index: EncryptedsearchIndex = self.getIndex(userID: userID)
        do {
            EncryptedSearchIndexService.shared.searchIndexSemaphore.wait()
            try index.openDBConnection()
            EncryptedSearchIndexService.shared.searchIndexSemaphore.signal()
        } catch {
            EncryptedSearchIndexService.shared.searchIndexSemaphore.signal()
            print("Error when opening DB connection: \(error)")
        }

        var batchCount: Int = 0
        var resultsFound: Int = numberOfResultsFoundByCachedSearch
        print("Start index search...")
        while !self.searchState!.isComplete && resultsFound < self.searchResultPageSize {
            let startBatchSearch: Double = CFAbsoluteTimeGetCurrent()

            let searchBatchHeapPercent: Double = 0.1 // Percentage of heap that can be used to load messages from the index
            let searchMsgSize: Double = 14000 // An estimation of how many bytes take a search message in memory
            let batchSize: Int = Int((getTotalAvailableMemory() * searchBatchHeapPercent)/searchMsgSize)
            //TODO

            var newResults: EncryptedsearchResultList? = EncryptedsearchResultList()
            do {
                EncryptedSearchIndexService.shared.searchIndexSemaphore.wait()
                newResults = try index.searchNewBatch(fromDB: searcher, cipher: cipher, state: self.searchState, batchSize: batchSize)
                EncryptedSearchIndexService.shared.searchIndexSemaphore.signal()
                resultsFound += newResults!.length()
            } catch {
                EncryptedSearchIndexService.shared.searchIndexSemaphore.signal()
                print("Error while searching... ", error)
            }

            // If some results are found - disable timer for slow search
            if resultsFound > 0 {
                DispatchQueue.main.async {
                    self.slowSearchTimer?.invalidate()
                    self.slowSearchTimer = nil
                    // start a new timer if search continues
                    self.slowSearchTimer = Timer.scheduledTimer(timeInterval: 5,
                                                                target: self,
                                                                selector: #selector(self.reactToSlowSearch),
                                                                userInfo: nil,
                                                                repeats: false)
                }
            }

            // Visualize intermediate results
            self.publishIntermediateResults(userID: userID,
                                            searchResults: newResults,
                                            searchViewModel: searchViewModel,
                                            currentPage: page)

            let endBatchSearch: Double = CFAbsoluteTimeGetCurrent()
            print("Batch \(batchCount) search. time: \(endBatchSearch-startBatchSearch), with batchsize: \(batchSize)")
            batchCount += 1
        }

        do {
            EncryptedSearchIndexService.shared.searchIndexSemaphore.wait()
            try index.closeDBConnection()
            EncryptedSearchIndexService.shared.searchIndexSemaphore.signal()
        } catch {
            EncryptedSearchIndexService.shared.searchIndexSemaphore.signal()
            print("Error while closing database Connection: \(error)")
        }

        let endIndexSearch: Double = CFAbsoluteTimeGetCurrent()
        print("Index search finished. Time: \(endIndexSearch-startIndexSearch)")

        return resultsFound
    }
    #endif

    private func getIndex(userID: String) -> EncryptedsearchIndex {
        let dbParams: EncryptedsearchDBParams = EncryptedSearchIndexService.shared.getDBParams(userID)
        let index: EncryptedsearchIndex = EncryptedsearchIndex(dbParams)!
        return index
    }

    #if !APP_EXTENSION
    private func doCachedSearch(searcher: EncryptedsearchSimpleSearcher,
                                cache: EncryptedsearchCache,
                                searchViewModel: SearchViewModel,
                                page: Int,
                                userID: String) -> Int {
        var found: Int = 0
        let batchSize: Int = Int(EncryptedSearchCacheService.shared.batchSize)
        var batchCount: Int = 0
        while !self.searchState!.cachedSearchDone && found < self.searchResultPageSize {
            let startCacheSearch: Double = CFAbsoluteTimeGetCurrent()

            var newResults: EncryptedsearchResultList? = EncryptedsearchResultList()
            do {
                newResults = try cache.search(self.searchState, searcher: searcher, batchSize: batchSize)
            } catch {
                print("Error when doing cache search \(error)")
            }
            found += (newResults?.length())!

            // If some results are found - disable timer for slow search
            if found > 0 {
                DispatchQueue.main.async {
                    self.slowSearchTimer?.invalidate()
                    self.slowSearchTimer = nil
                    // start a new timer if search continues
                    self.slowSearchTimer = Timer.scheduledTimer(timeInterval: 5, target: self, selector: #selector(self.reactToSlowSearch), userInfo: nil, repeats: false)
                }
            }

            // Visualize intermediate results
            self.publishIntermediateResults(userID: userID, searchResults: newResults, searchViewModel: searchViewModel, currentPage: page)

            let endCacheSearch: Double = CFAbsoluteTimeGetCurrent()
            print("Cache batch \(batchCount) search: \(endCacheSearch-startCacheSearch) seconds, batchSize: \(batchSize)")
            batchCount += 1
        }
        return found
    }
    #endif

    #if !APP_EXTENSION
    private func publishIntermediateResults(userID: String, searchResults: EncryptedsearchResultList?, searchViewModel: SearchViewModel, currentPage: Int){
        self.extractSearchResults(userID: userID, searchResults: searchResults!) { messageBatch in
            let messages: [Message.ObjectIDContainer]? = messageBatch!.map(ObjectBox.init)
            searchViewModel.displayIntermediateSearchResults(messageBoxes: messages, currentPage: currentPage)
        }
    }
    #endif

    // MARK: - Background Tasks
    //pre-ios 13 background tasks
    @available(iOSApplicationExtension, unavailable, message: "This method is NS_EXTENSION_UNAVAILABLE")
    public func continueIndexingInBackground(userID: String) {
        print("ES extend indexing in background")
        self.speedUpIndexing(userID: userID)
        self.backgroundTask = UIApplication.shared.beginBackgroundTask(expirationHandler: {
            self.endBackgroundTask()
        })
    }

    //pre-ios 13 background tasks
    @available(iOSApplicationExtension, unavailable, message: "This method is NS_EXTENSION_UNAVAILABLE")
    public func endBackgroundTask() {
        print("ES end extended indexing as time runs out")
        UIApplication.shared.endBackgroundTask(self.backgroundTask)
        self.backgroundTask = .invalid
    }

    // BG Processing Task functions
    @available(iOS 13.0, *)
    @available(iOSApplicationExtension, unavailable, message: "This method is NS_EXTENSION_UNAVAILABLE")
    func registerBGProcessingTask() {
        self.encryptedSearchBGProcessingTaskRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: "ch.protonmail.protonmail.encryptedsearch_indexbuilding", using: nil) { bgTask in
            self.bgProcessingTask(task: bgTask as! BGProcessingTask)
        }
        if !self.encryptedSearchBGProcessingTaskRegistered {
            print("Error when registering background processing task!")
        }
    }

    @available(iOS 13.0, *)
    private func cancelBGProcessingTask() {
        guard self.encryptedSearchBGProcessingTaskRegistered else {
            return
        }

        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: "ch.protonmail.protonmail.encryptedsearch_indexbuilding")
    }

    @available(iOS 13.0, *)
    private func scheduleNewBGProcessingTask() {
        guard self.encryptedSearchBGProcessingTaskRegistered else {
            return
        }

        let request = BGProcessingTaskRequest(identifier: "ch.protonmail.protonmail.encryptedsearch_indexbuilding")
        request.requiresNetworkConnectivity = true

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Error when scheduling index building background task: \(error)")
        }
    }

    @available(iOS 13.0, *)
    private func bgProcessingTask(task: BGProcessingTask) {
        // Check if user is known
        let usersManager: UsersManager = sharedServices.get(by: UsersManager.self)
        guard let userID = usersManager.firstUser?.userInfo.userId else {
            print("Error when running bg processing task. User unknown!")
            task.setTaskCompleted(success: true)
            return
        }

        // Provide an expiration handler in case indexing is not finished in time
        task.expirationHandler = {
            // Schedule a new background processing task if index building is not finished
            self.scheduleNewBGProcessingTask()

            self.setESState(userID: userID, indexingState: .backgroundStopped)

            // Slow down indexing again - will be speed up if user switches to ES screen
            self.slowDownIndexing(userID: userID)
        }

        // Index is build in foreground - no need for a background task
        if self.getESState(userID: userID) == .downloading {
            task.setTaskCompleted(success: true)
        } else {
            // Check if indexing is in progress
            let expectedESStates: [EncryptedSearchIndexState] = [.undetermined, .disabled, .complete, .partial]
            if expectedESStates.contains(self.getESState(userID: userID)) {
                task.setTaskCompleted(success: true)
                return
            }

            self.setESState(userID: userID, indexingState: .background)

            // in the background we can index with full speed
            self.speedUpIndexing(userID: userID)

            // Start indexing in background
            self.pauseAndResumeIndexingDueToInterruption(isPause: false, userID: userID)
        }
    }

    @available(iOS 13.0, *)
    @available(iOSApplicationExtension, unavailable, message: "This method is NS_EXTENSION_UNAVAILABLE")
    func registerBGAppRefreshTask() {
        self.encryptedSearchBGAppRefreshTaskRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: "ch.protonmail.protonmail.encryptedsearch_apprefresh", using: nil) { bgTask in
            self.appRefreshTask(task: bgTask as! BGAppRefreshTask)
        }
        if !self.encryptedSearchBGAppRefreshTaskRegistered {
            print("Error when registering background app refresh task!")
        }
    }

    @available(iOS 13.0, *)
    private func cancelBGAppRefreshTask() {
        guard self.encryptedSearchBGAppRefreshTaskRegistered else {
            return
        }

        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: "ch.protonmail.protonmail.encryptedsearch_apprefresh")
    }

    @available(iOS 13.0, *)
    private func scheduleNewAppRefreshTask() {
        guard self.encryptedSearchBGAppRefreshTaskRegistered else {
            return
        }

        let request = BGAppRefreshTaskRequest(identifier: "ch.protonmail.protonmail.encryptedsearch_apprefresh")

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Unable to sumit app refresh task: \(error.localizedDescription)")
        }
    }

    @available(iOS 13.0, *)
    private func appRefreshTask(task: BGAppRefreshTask) {
        // Check if user is known
        let usersManager: UsersManager = sharedServices.get(by: UsersManager.self)
        guard let userID = usersManager.firstUser?.userInfo.userId else {
            print("Error when running bg apprefresh task. User unknown!")
            task.setTaskCompleted(success: true)
            return
        }

        // Provide an expiration handler in case indexing is not finished in time
        task.expirationHandler = {
            // Schedule a new background app refresh task
            self.scheduleNewAppRefreshTask()

            self.setESState(userID: userID, indexingState: .backgroundStopped)

            // Slow down indexing again - will be speed up if user switches to ES screen
            self.slowDownIndexing(userID: userID)
        }

        // Index is build in foreground - no need for a background task
        if self.getESState(userID: userID) == .downloading {
            task.setTaskCompleted(success: true)
        } else {
            // Check if indexing is in progress
            let expectedESStates: [EncryptedSearchIndexState] = [.undetermined, .disabled, .complete, .partial]
            if expectedESStates.contains(self.getESState(userID: userID)) {
                task.setTaskCompleted(success: true)
                return
            }

            self.setESState(userID: userID, indexingState: .background)

            // in the background we can index with full speed
            self.speedUpIndexing(userID: userID)

            // Start indexing in background
            self.pauseAndResumeIndexingDueToInterruption(isPause: false, userID: userID)
        }
    }

    // MARK: - Analytics/Metrics Functions
    enum Metrics {
        case index
        case search
    }

    private func sendIndexingMetrics(indexTime: Double, userID: String) {
        let indexSize: Int64? = EncryptedSearchIndexService.shared.getSizeOfSearchIndex(for: userID).asInt64 ?? 0
        let numMessagesIndexed: Int = EncryptedSearchIndexService.shared.getNumberOfEntriesInSearchIndex(for: userID)
        let indexingMetricsData: [String:Any] = ["numMessagesIndexed" : numMessagesIndexed,
                                                 "indexSize"          : indexSize!,
                                                 "indexTime"          : Int(indexTime),
                                                 "originalEstimate"   : userCachedStatus.encryptedSearchInitialIndexingTimeEstimate,
                                                 "numPauses"          : userCachedStatus.encryptedSearchNumberOfPauses,
                                                 "numInterruptions"   : userCachedStatus.encryptedSearchNumberOfInterruptions,
                                                 "isRefreshed"        : userCachedStatus.encryptedSearchIsExternalRefreshed]
        self.sendMetrics(metric: Metrics.index, data: indexingMetricsData){_,_,error in
            if error != nil {
                print("Error when sending indexing metrics: \(String(describing: error))")
            }
        }
    }
    
    private func sendSearchMetrics(searchTime: Double, cache: EncryptedsearchCache?, userID: String){
        let indexSize: Int64? = EncryptedSearchIndexService.shared.getSizeOfSearchIndex(for: userID).asInt64 ?? 0
        let numMessagesIndexed = EncryptedSearchIndexService.shared.getNumberOfEntriesInSearchIndex(for: userID)
        let cacheSize: Int64? = cache?.getSize() ?? 0
        let isCacheLimited: Bool = cache?.isPartial() ?? false
        let searchMetricsData: [String:Any] = ["numMessagesIndexed" : numMessagesIndexed,
                                               "indexSize"          : indexSize!,
                                               "cacheSize"          : cacheSize!,
                                               "isFirstSearch"      : self.isFirstSearch,
                                               "isCacheLimited"     : isCacheLimited,
                                               "searchTime"         : Int(searchTime*100)]   // Search time is expressed in milliseconds instead of seconds
        self.sendMetrics(metric: Metrics.search, data: searchMetricsData){_,_,error in
            if error != nil {
                print("Error when sending search metrics: \(String(describing: error))")
            }
        }
    }

    private func sendMetrics(metric: Metrics, data: [String: Any], completion: @escaping CompletionBlock) {
        var title: String = ""
        switch metric {
        case .index:
            title = "index"
        case .search:
            title = "search"
        }

        if metric == .search {
            let delay: Int = Int.random(in: 1...180) // add a random delay between 1 second and 3 minutes
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay)) {
                self.apiService?.metrics(log: "encrypted_search", title: title, data: data, completion: completion)
            }
        } else {
            self.apiService?.metrics(log: "encrypted_search", title: title, data: data, completion: completion)
        }
    }

    // MARK: - Helper Functions
    func setESState(userID: String, indexingState: EncryptedSearchIndexState) {
        print("ENCRYPTEDSEARCH-STATE: \(indexingState)")

        let stateValue: String = userID + "-" + String(indexingState.rawValue)
        let stateKey: String = "ES-INDEXSTATE-" + userID

        KeychainWrapper.keychain.set(stateValue, forKey: stateKey)
    }

    func getESState(userID: String) -> EncryptedSearchIndexState {
        let stateKey: String = "ES-INDEXSTATE-" + userID
        var indexingState: EncryptedSearchIndexState = .undetermined
        if let stateValue = KeychainWrapper.keychain.string(forKey: stateKey) {
            let index = stateValue.index(stateValue.endIndex, offsetBy: -1)
            let state: String = String(stateValue.suffix(from: index))
            indexingState = EncryptedSearchIndexState(rawValue: Int(state) ?? 0) ?? .undetermined
        } else {
            print("Error: no ES state found for userID: \(userID)")
            indexingState = .disabled
        }
        return indexingState
    }

    private func initializeOperationQueues() {
        self.messageIndexingQueue = OperationQueue()
        self.messageIndexingQueue?.name = "Message Indexing Queue"
        self.messageIndexingQueue?.maxConcurrentOperationCount = self.indexingSpeed

        self.downloadPageQueue = OperationQueue()
        self.downloadPageQueue?.name = "Download Page Queue"
        self.downloadPageQueue?.maxConcurrentOperationCount = 1 // Download 1 page at a time
    }

    private func deleteAndClearOperationQueues(completion: (() -> Void)?) {
        // Suspend message queues to stop processing tasks
        self.downloadPageQueue?.isSuspended = true
        self.messageIndexingQueue?.isSuspended = true

        self.downloadPageQueue?.cancelAllOperations()
        self.downloadPageQueue = nil

        self.messageIndexingQueue?.cancelAllOperations()
        self.messageIndexingQueue = nil

        completion?()
    }

    func isIndexingInProgress(userID: String) -> Bool {
        // Check state
        let expectedESStates: [EncryptedSearchIndexState] = [.downloading, .background, .refresh, .paused]
        if expectedESStates.contains(self.getESState(userID: userID)) {
            // check if there are some operations scheduled
            if let messageIndexingQueue = self.messageIndexingQueue, let downloadPageQueue = self.downloadPageQueue {
                if messageIndexingQueue.operationCount > 0 || downloadPageQueue.operationCount > 0 {
                    return true
                }
            }
        }

        return false
    }

    // Called to slow down indexing - so that a user can normally use the app
    func slowDownIndexing(userID: String) {
        let expectedESStates: [EncryptedSearchIndexState] = [.downloading, .background, .refresh]
        if expectedESStates.contains(self.getESState(userID: userID)) {
            self.indexingSpeed = 5
            self.pageSize = 50
            self.slowDownIndexBuilding = true
        }
    }

    // speed up indexing again when in foreground
    func speedUpIndexing(userID: String) {
        self.slowDownIndexBuilding = false
        let expectedESStates: [EncryptedSearchIndexState] = [.downloading, .background, .refresh]
        if expectedESStates.contains(self.getESState(userID: userID)) {
            // Adapt indexing speed according to RAM usage
            self.adaptIndexingSpeed()
        }
    }

    private func createMessageFromPreview(userID: String, searchResult: EncryptedsearchSearchResult?) -> Message {
        let msg: EncryptedsearchMessage = searchResult!.message!

        let type: Int = 0
        let recipient: EncryptedsearchRecipient? = msg.decryptedContent?.sender
        let senderAddress: String = recipient?.email ?? ""
        let senderName: String = recipient?.name ?? ""
        let sender: ESSender = ESSender(Name: senderName, Address: senderAddress)

        let toList: [ESSender?] = self.recipientListToESSenderArray(recipientList: msg.decryptedContent?.toList)
        let ccList: [ESSender?] = self.recipientListToESSenderArray(recipientList: msg.decryptedContent?.ccList)
        let bccList: [ESSender?] = self.recipientListToESSenderArray(recipientList: msg.decryptedContent?.bccList)

        let size: Int = (searchResult?.getBodyPreview() ?? "").utf8.count
        let isEncrypted: Int = 1
        let spamScore: Int? = nil
        let externalID: String? = nil
        let header: String? = nil
        let mimeType: String? = nil

        let esMessage: ESMessage = ESMessage(id: msg.id_,
                                             order: Int(truncatingIfNeeded: msg.order),
                                             conversationID: msg.decryptedContent?.conversationID ?? "",
                                             subject: msg.decryptedContent?.subject ?? "",
                                             unread: msg.decryptedContent!.unread ? 1:0,
                                             type: type,
                                             senderAddress: senderAddress,
                                             senderName: senderName,
                                             sender: sender,
                                             toList: toList,
                                             ccList: ccList,
                                             bccList: bccList,
                                             time: Double(msg.time),
                                             size: size,
                                             isEncrypted: isEncrypted,
                                             expirationTime: Date(timeIntervalSince1970: Double(msg.decryptedContent?.expirationTime ?? 0)),
                                             isReplied: msg.decryptedContent!.isReplied ? 1:0,
                                             isRepliedAll: msg.decryptedContent!.isRepliedAll ? 1:0,
                                             isForwarded: msg.decryptedContent!.isForwarded ? 1:0,
                                             spamScore: spamScore,
                                             addressID: msg.decryptedContent?.addressID,
                                             numAttachments: msg.decryptedContent?.numAttachments ?? 0,
                                             flags: Int(truncatingIfNeeded: msg.decryptedContent?.flags ?? 0),
                                             labelIDs: Set(msg.labelIds.components(separatedBy: ";")),
                                             externalID: externalID,
                                             body: searchResult?.getBodyPreview(),
                                             header: header,
                                             mimeType: mimeType,
                                             userID: userID)
        esMessage.isStarred = msg.decryptedContent?.isStarred ?? false
        esMessage.isDetailsDownloaded = true

        return esMessage.toMessage()
    }

    private func recipientListToESSenderArray(recipientList: EncryptedsearchRecipientList?) -> [ESSender?] {
        guard let recipientList = recipientList else {
            return []
        }

        var senderArray: [ESSender?] = []
        for index in 0...recipientList.length() {
            let recipient: EncryptedsearchRecipient? = recipientList.get(index)
            if let recipient = recipient {
                senderArray.append(ESSender(Name: recipient.name, Address: recipient.email))
            }
        }
        return senderArray
    }

    private func checkIfEnoughStorage(userID: String) -> Bool {
        // Check if indexing is in progress
        let expectedESStates: [EncryptedSearchIndexState] = [.undetermined, .disabled, .complete]
        if expectedESStates.contains(self.getESState(userID: userID)) {
            return true
        }

        let remainingStorageSpace = self.getFreeDiskSpace()
        if remainingStorageSpace < self.lowStorageLimit  {    // 100 MB
            // Run on seperate thread to prevent the app from being unresponsive
            DispatchQueue.global(qos: .userInitiated).async {
                // Cancle any running indexing process
                self.deleteAndClearOperationQueues() {
                    // Set state to lowstorage
                    self.setESState(userID: userID, indexingState: .lowstorage)

                    // clean up indexing
                    self.cleanUpAfterIndexing(userID: userID)
                }
            }
            return false
        }
        return true
    }

    private func checkIfStorageLimitIsExceeded(userID: String) -> Bool {
        // Check if indexing is in progress
        let expectedESStates: [EncryptedSearchIndexState] = [.undetermined, .disabled, .complete]
        if expectedESStates.contains(self.getESState(userID: userID)) {
            return false
        }

        // Check if storage limit is unlimited
        if userCachedStatus.storageLimit == -1 {
            return false
        }

        let sizeOfSearchIndex: Int64? = EncryptedSearchIndexService.shared.getSizeOfSearchIndex(for: userID).asInt64
        if sizeOfSearchIndex! > (userCachedStatus.storageLimit - 2_000) {   // stop indexing 2MB before hitting the storage limit
            // Run on seperate thread to prevent the app from being unresponsive
            DispatchQueue.global(qos: .userInitiated).async {
                // Cancle any running indexing process
                self.deleteAndClearOperationQueues() {
                    // Set state to partial
                    self.setESState(userID: userID, indexingState: .partial)

                    // clean up indexing
                    self.cleanUpAfterIndexing(userID: userID)
                }
            }
            return true
        }
        return false
    }

    public func estimateIndexingTime() -> (estimatedTime: String?, time: Double, currentProgress: Int){
        var estimatedTime: Double = 0
        var currentProgress: Int = 0
        let currentTime: Double = CFAbsoluteTimeGetCurrent()

        if userCachedStatus.encryptedSearchTotalMessages != 0 && currentTime != userCachedStatus.encryptedSearchIndexingStartTime && userCachedStatus.encryptedSearchProcessedMessages != userCachedStatus.encryptedSearchPreviousProcessedMessages {
            let remainingMessages: Double = Double(userCachedStatus.encryptedSearchTotalMessages - userCachedStatus.encryptedSearchProcessedMessages)
            let timeDifference: Double = currentTime-userCachedStatus.encryptedSearchIndexingStartTime
            let processedMessageDifference: Double = Double(userCachedStatus.encryptedSearchProcessedMessages-userCachedStatus.encryptedSearchPreviousProcessedMessages)

            // Estimate time (in seconds)
            estimatedTime = ceil((timeDifference/processedMessageDifference)*remainingMessages)
            // Estimate progress (in percent)
            currentProgress = Int(ceil((Double(userCachedStatus.encryptedSearchProcessedMessages)/Double(userCachedStatus.encryptedSearchTotalMessages))*100))
        }

        return (self.timeToDate(time: estimatedTime), estimatedTime, currentProgress)
    }

    @objc private func updateRemainingIndexingTime() {
        let usersManager: UsersManager = sharedServices.get(by: UsersManager.self)
        if let userID = usersManager.firstUser?.userInfo.userId {
            // Stop timer if indexing is finished or paused
            let expectedESStates: [EncryptedSearchIndexState] = [.complete, .partial, .paused, .undetermined, .disabled]
            if expectedESStates.contains(self.getESState(userID: userID)) {
                // Invalidate timer on same thread as it has been created
                DispatchQueue.main.async {
                    self.indexBuildingTimer?.invalidate()
                }
            }

            if self.getESState(userID: userID) == .downloading {
                DispatchQueue.global().async {
                    let result = self.estimateIndexingTime()

                    if userCachedStatus.encryptedSearchIsInitialIndexingTimeEstimate {
                        userCachedStatus.encryptedSearchInitialIndexingTimeEstimate = Int(result.time)  // provide the initial estimate in seconds
                        userCachedStatus.encryptedSearchIsInitialIndexingTimeEstimate = false
                    }

                    // Update UI
                    if result.currentProgress != 0 {
                        self.viewModel?.currentProgress.value = result.currentProgress > 100 ? 100 : result.currentProgress
                    }

                    // Just show an time estimate after a few rounds (to have a more stable estimate)
                    var waitRoundsBeforeShowingTimeEstimate: Int = 3
                    if userCachedStatus.encryptedSearchTotalMessages > 50_000 {
                        waitRoundsBeforeShowingTimeEstimate = 5
                    } else {
                        waitRoundsBeforeShowingTimeEstimate = 3
                    }
                    if self.estimateIndexTimeRounds >= waitRoundsBeforeShowingTimeEstimate {
                        self.viewModel?.estimatedTimeRemaining.value = result.estimatedTime
                    } else {
                        self.estimateIndexTimeRounds += 1
                        self.viewModel?.estimatedTimeRemaining.value = nil
                    }
                    print("Remaining indexing time (seconds): \(String(describing: result.time))")
                    print("Current progress: \(result.currentProgress)")
                    print("Indexing rate: \(String(describing: self.messageIndexingQueue?.maxConcurrentOperationCount))")
                }
            }

            // Check if there is still enought storage left
            _ = self.checkIfEnoughStorage(userID: userID)
            _ = self.checkIfStorageLimitIsExceeded(userID: userID)
            if self.slowDownIndexBuilding { // Re-evaluate indexing speed while not beeing on indexing screen
                self.slowDownIndexing(userID: userID)
            }

            // Adapt indexing speed due to RAM usage
            self.adaptIndexingSpeed()

            // print state for debugging
            print("ES-DEBUG: \(self.getESState(userID: userID))")
        }
    }

    private func timeToDate(time: Double) -> String? {
        if time < 60 {
            return LocalString._encrypted_search_estimated_time_less_than_a_minute
        }

        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .full    // spells out units
        formatter.includesTimeRemainingPhrase = true    // adds remaining in the end
        formatter.zeroFormattingBehavior = .dropLeading // drops leading units that are zero

        return formatter.string(from: time)
    }

    private func registerForPowerStateChangeNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(responseToLowPowerMode(_:)), name: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil)
    }

    @available(iOS 12, *)
    private func registerForNetworkChangeNotifications() {
        // Create network monitor - if not already existing
        if self.networkMonitor == nil {
            self.networkMonitor = NWPathMonitor()
            self.networkMonitor?.pathUpdateHandler = { path in
                self.responseToNetworkChanges(path: path)
            }
        }

        // Start network monitoring - if not already running
        if self.networkMonitoringQueue == nil {
            self.networkMonitoringQueue = DispatchQueue(label: "NetworkMonitor")
            self.networkMonitor?.start(queue: networkMonitoringQueue!)
            print("ES-NETWORK: start monitoring network changes")
        }
    }

    /*private func registerForNetworkChangeNotificationsAllIOS() {
        if self.networkMonitorAllIOS == nil {
            self.networkMonitorAllIOS = InternetConnectionStatusProvider()
        }
        print("ES-NETWORK: start network monitoring")
        self.networkMonitorAllIOS?.getConnectionStatuses { [weak self] status in
            if status.isConnected {
                print("ES-NETWORK: internet connection available")
                if self?.networkMonitorAllIOS?.currentStatus == .ReachableViaWiFi {
                    print("ES-NETWORK: wifi available")
                }
            } else {
                print("ES-NETWORK: no internet connection")
            }
        }
    }
    
    private func unregisterForNetworkChangeNotificationsAllIOS() {
        print("ES-NETWORK: stop network monitoring")
        self.networkMonitorAllIOS?.stopInternetConnectionStatusObservation()
    }*/

    @available(iOS 12, *)
    private func unRegisterForNetworkChangeNotifications() {
        self.networkMonitor?.cancel()
        self.networkMonitor = nil
        self.networkMonitoringQueue = nil
        print("ES-NETWORK: stop monitoring network changes")
    }

    @available(iOS 12, *)
    private func responseToNetworkChanges(path: NWPath) {
        // Check if user is known
        let usersManager: UsersManager = sharedServices.get(by: UsersManager.self)
        guard let userID = usersManager.firstUser?.userInfo.userId else {
            print("Error when responding to network changes. User unknown!")
            return
        }

        // Check if indexing is in progress
        let expectedESStates: [EncryptedSearchIndexState] = [.undetermined, .disabled, .complete, .partial]
        if expectedESStates.contains(self.getESState(userID: userID)) {
            return
        }

        if path.status == .satisfied {
            // Either cellular or a WiFi hotspot
            if path.isExpensive {
                print("ES-NETWORK cellular")

                // If indexing with mobile data is enabled
                if userCachedStatus.downloadViaMobileData {
                    print("ES-NETWORK cellular - mobile data on")

                    // Update some state variables
                    self.pauseIndexingDueToWiFiNotDetected = false
                    self.pauseIndexingDueToNetworkConnectivityIssues = false

                    // If indexing was paused - resume indexing
                    if self.getESState(userID: userID) == .paused {
                        self.pauseAndResumeIndexingDueToInterruption(isPause: false, userID: userID)
                    }
                } else {
                    // Mobile data available - however user switched indexing on mobile data off
                    print("ES-NETWORK cellular - mobile data off")

                    // Update some state variables
                    self.pauseIndexingDueToWiFiNotDetected = true
                    self.pauseIndexingDueToNetworkConnectivityIssues = false

                    // If downloading - Pause indexing
                    if self.getESState(userID: userID) == .downloading {
                        self.pauseAndResumeIndexingDueToInterruption(isPause: true, userID: userID)
                    }
                }
            } else {    // WiFi available
                print("ES-NETWORK wifi")

                // Update some state variables
                self.pauseIndexingDueToWiFiNotDetected = false
                self.pauseIndexingDueToNetworkConnectivityIssues = false

                // If indexing was paused - continue on wifi again
                if self.getESState(userID: userID) == .paused {
                    self.pauseAndResumeIndexingDueToInterruption(isPause: false, userID: userID)
                }
            }
        } else {
            print("ES-NETWORK No Internet available")

            // Update state variable
            self.pauseIndexingDueToNetworkConnectivityIssues = true
            self.pauseIndexingDueToWiFiNotDetected = true

            // Pause indexing
            if self.getESState(userID: userID) == .downloading {
                self.pauseAndResumeIndexingDueToInterruption(isPause: true, userID: userID)
            }
        }

        // Update UI
        self.updateUIWithIndexingStatus(userID: userID)
    }

    @available(iOS 12, *)
    func checkIfNetworkAvailable() {
        // Run on a separate thread so that UI is not blocked
        DispatchQueue.global(qos: .userInitiated).async {
            // Check if network monitoring is enabled - otherwise enable it
            if self.networkMonitor == nil {
                self.registerForNetworkChangeNotifications()
            }

            // Check current network path
            if let networkPath = self.networkMonitor?.currentPath {
                self.responseToNetworkChanges(path: networkPath)
            } else {
                print("ES-NETWORK: Error when determining network status!")
            }
        }
    }

    private func isInternetConnection() -> Bool {
        guard let reachability = Reachability.forInternetConnection() else {
            return false
        }
        if reachability.currentReachabilityStatus() == .NotReachable {
            return false
        }
        return true
    }

    @objc private func responseToLowPowerMode(_ notification: Notification) {
        // Check if user is known
        let usersManager: UsersManager = sharedServices.get(by: UsersManager.self)
        guard let userID = usersManager.firstUser?.userInfo.userId else {
            print("Error when responding to low power mode. User unknown!")
            return
        }

        // Check if indexing is in progress
        let expectedESStates: [EncryptedSearchIndexState] = [.undetermined, .disabled, .complete, .partial]
        if expectedESStates.contains(self.getESState(userID: userID)) {
            return
        }

        if ProcessInfo.processInfo.isLowPowerModeEnabled && !self.pauseIndexingDueToLowBattery {
            // Low power mode is enabled - pause indexing
            self.pauseIndexingDueToLowBattery = true
            print("Pause indexing due to low battery!")
            self.pauseAndResumeIndexingDueToInterruption(isPause: true, userID: userID)
        } else if !ProcessInfo.processInfo.isLowPowerModeEnabled && self.pauseIndexingDueToLowBattery {
            // Low power mode is disabled - continue indexing
            self.pauseIndexingDueToLowBattery = false
            print("Resume indexing as battery is charged again!")
            self.pauseAndResumeIndexingDueToInterruption(isPause: false, userID: userID)
        }
    }

    private func registerForTermalStateChangeNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(responseToHeat(_:)), name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    }

    @objc private func responseToHeat(_ notification: Notification) {
        // Check if user is known
        let usersManager: UsersManager = sharedServices.get(by: UsersManager.self)
        guard let userID = usersManager.firstUser?.userInfo.userId else {
            print("Error when responding to iPhone heating up. User unknown!")
            return
        }

        // Check if indexing is in progress
        let expectedESStates: [EncryptedSearchIndexState] = [.undetermined, .disabled, .complete, .partial]
        if expectedESStates.contains(self.getESState(userID: userID)) {
            return
        }

        let termalState = ProcessInfo.processInfo.thermalState
        switch termalState {
        case .nominal:
            print("Thermal state nomial. No further action required")
            if self.pauseIndexingDueToOverheating {
                self.pauseIndexingDueToOverheating = false
                self.pauseAndResumeIndexingDueToInterruption(isPause: false, userID: userID)    // Resume indexing
            }
        case .fair:
            print("Thermal state fair. No further action required")
            if self.pauseIndexingDueToOverheating {
                self.pauseIndexingDueToOverheating = false
                self.pauseAndResumeIndexingDueToInterruption(isPause: false, userID: userID)    // Resume indexing
            }
        case .serious:
            print("Thermal state serious. Reduce CPU usage.")
        case .critical:
            print("Thermal state critical. Stop indexing!")
            self.pauseIndexingDueToOverheating = true
            self.pauseAndResumeIndexingDueToInterruption(isPause: true, userID: userID)    // Pause indexing
        @unknown default:
            break
        }
    }

    #if !APP_EXTENSION
    public func getSizeOfCachedData() -> (asInt64: Int64?, asString: String) {
        var sizeOfCachedData: Int64 = 0
        do {
            let data: Data = try Data(contentsOf: CoreDataStore.dbUrl)
            sizeOfCachedData = Int64(data.count)
        } catch let error {
            print("Error when calculating size of cached data: \(error.localizedDescription)")
        }
        return (sizeOfCachedData, ByteCountFormatter.string(fromByteCount: sizeOfCachedData, countStyle: ByteCountFormatter.CountStyle.file))
    }
    #endif

    #if !APP_EXTENSION
    func deleteCachedData(userID: String, localStorageViewModel: SettingsLocalStorageViewModel) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.updateUserAndAPIServices()

            self.deletingCacheInProgress = true
            // Clean all cached messages
            _ = self.messageService?.cleanMessage(cleanBadgeAndNotifications: true).done { (_) in
                self.messageService?.lastUpdatedStore.clear()
                self.messageService?.lastUpdatedStore.removeUpdateTime(by: userID, type: .singleMessage)
                self.messageService?.lastUpdatedStore.removeUpdateTime(by: userID, type: .conversation)
                localStorageViewModel.isCachedDataDeleted.value = true
                self.deletingCacheInProgress = false
            }
        }
    }
    #endif

    #if !APP_EXTENSION
    public func calculateSizeOfAttachments() -> (asInt64: Int64?, asString: String) {
        let pathToAttachmentsFolder: String = FileManager.default.temporaryDirectory.path + "/attachments"
        var sizeOfAttachments: Int64 = 0
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: pathToAttachmentsFolder)
            for content in contents {
                do {
                    let fullContentPath = pathToAttachmentsFolder + "/" + content
                    let fileAttributes = try FileManager.default.attributesOfItem(atPath: fullContentPath)
                    sizeOfAttachments += fileAttributes[FileAttributeKey.size] as? Int64 ?? 0
                } catch _ {
                    continue
                }
            }
        } catch let error {
            print("Error when calculating size of attachments: \(error.localizedDescription)")
        }
        return (sizeOfAttachments, ByteCountFormatter.string(fromByteCount: sizeOfAttachments, countStyle: ByteCountFormatter.CountStyle.file))
    }
    #endif

    #if !APP_EXTENSION
    func deleteAttachments(localStorageViewModel: SettingsLocalStorageViewModel) {
        DispatchQueue.global(qos: .userInitiated).async {
            let pathToAttachmentsFolder: String = FileManager.default.temporaryDirectory.path + "/attachments"
            do {
                let contents = try FileManager.default.contentsOfDirectory(atPath: pathToAttachmentsFolder)
                for content in contents {
                    do {
                        let fullContentPath = pathToAttachmentsFolder + "/" + content
                        try FileManager.default.removeItem(atPath: fullContentPath)
                        localStorageViewModel.areAttachmentsDeleted.value = true
                    } catch _ {
                        continue
                    }
                }
            } catch let error {
                print("Error when deleting attachments: \(error.localizedDescription)")
            }
        }
    }
    #endif

    private func updateUIWithIndexingStatus(userID: String) {
        DispatchQueue.main.async {
            if self.pauseIndexingDueToNetworkConnectivityIssues {
                self.viewModel?.interruptStatus.value = LocalString._encrypted_search_download_paused_no_connectivity
                self.viewModel?.interruptAdvice.value = LocalString._encrypted_search_download_paused_no_connectivity_status
                return
            }
            if self.pauseIndexingDueToWiFiNotDetected {
                self.viewModel?.interruptStatus.value = LocalString._encrypted_search_download_paused_no_wifi
                self.viewModel?.interruptAdvice.value = LocalString._encrypted_search_download_paused_no_wifi_status
                return
            }
            if self.pauseIndexingDueToLowBattery {
                self.viewModel?.interruptStatus.value = LocalString._encrypted_search_download_paused_low_battery
                self.viewModel?.interruptAdvice.value = LocalString._encrypted_search_download_paused_low_battery_status
                return
            }
            if self.getESState(userID: userID) == .lowstorage {
                self.viewModel?.interruptStatus.value = LocalString._encrypted_search_download_paused_low_storage
                self.viewModel?.interruptAdvice.value = LocalString._encrypted_search_download_paused_low_storage_status
                return
            }
            let expectedESStates: [EncryptedSearchIndexState] = [.complete, .partial]
            if expectedESStates.contains(self.getESState(userID: userID)) {
                self.viewModel?.isIndexingComplete.value = true
                #if !APP_EXTENSION
                    self.searchViewModel?.encryptedSearchIndexingComplete = true
                #endif
            }
            // No interrupt
            self.viewModel?.interruptStatus.value = nil
            self.viewModel?.interruptAdvice.value = nil
        }
    }

    func updateProgressedMessagesUI() {
        self.viewModel?.progressedMessages.value = userCachedStatus.encryptedSearchProcessedMessages
        self.viewModel?.currentProgress.value = Int(ceil((Double(userCachedStatus.encryptedSearchProcessedMessages)/Double(userCachedStatus.encryptedSearchTotalMessages))*100))
    }

    func highlightKeyWords(bodyAsHtml: String) -> String {
        // check if there are any keywords
        guard !self.searchQuery.isEmpty else {
            return bodyAsHtml
        }

        // replace occurences of &nbsp; with normal spaces as it cause problems when highlighting
        var htmlWithHighlightedKeywords = bodyAsHtml.replacingOccurrences(of: "&nbsp;", with: " ")
        do {
            let doc: Document = try SwiftSoup.parse(htmlWithHighlightedKeywords)
            if let body = doc.body() {
                try self.highlightSearchKeyWordsInHtml(parentNode: body, keyWords: self.searchQuery)
            }

            // fix bug with newlines and whitespaces added
            htmlWithHighlightedKeywords = try self.documentToHTMLString(document: doc)
        } catch {
            print("Error when parsing the Html DOM tree for highlighting keywords")
        }

        return htmlWithHighlightedKeywords
    }

    private func documentToHTMLString(document: Document) throws -> String {
        var html = ""
        let body = document.body()
        for node in body!.getChildNodes() {
            let htmlString = try node.outerHtml()
            if htmlString.contains(check: "mark") {
                // split string by newlines
                let stringArray = htmlString.components(separatedBy: "\n")
                // rebuild string
                var newHtmlString: String = ""
                for substring in stringArray {
                    // remove leading whitespaces only
                    newHtmlString += substring.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
                }
                html += newHtmlString
            } else {
                html += htmlString
            }
        }
        return html
    }

    private func highlightSearchKeyWordsInHtml(parentNode: Element?, keyWords: [String]) throws {
        guard let parentNode = parentNode else {
            return
        }

        for node in parentNode.getChildNodes() {
            if let textNode = node as? TextNode {
                if textNode.isBlank() {
                    continue
                }
                if let newelement = try self.applyMarkUp(textNode: textNode, keywords: keyWords) {
                    try node.replaceWith(newelement as Node)
                }
            } else {
                try self.highlightSearchKeyWordsInHtml(parentNode: node as? Element, keyWords: keyWords)
            }
        }
    }

    private func applyMarkUp(textNode: TextNode, keywords: [String]) throws -> Element? {
        let text: String = textNode.getWholeText().precomposedStringWithCanonicalMapping
        let positions = self.findKeywordsPositions(text: text, keywords: keywords)

        if !positions.isEmpty {
            var span: Element = Element(Tag("span"), "")
            var lastIndex: Int = 0
            for position in positions {
                span = try span.appendChild(TextNode(self.substring(value: text, from: lastIndex, to: position.0), ""))
                var markNode: Element = Element(Tag("mark"), "")
                try markNode.attr("style", "background-color: \(UIColor.dynamic(light: ColorProvider.BrandLighten20, dark: ColorProvider.BrandLighten20).toHex())")
                markNode = try markNode.appendChild(TextNode(self.substring(value: text, from: position.0, to: position.1), ""))
                span = try span.appendChild(markNode)
                lastIndex = position.1
            }
            if lastIndex < text.count {
                span = try span.appendChild(TextNode(self.substring(value: text, from: lastIndex, to: text.count), ""))
            }
            return span
        }
        return nil
    }

    private func substring(value: String, from: Int, to: Int) -> String {
        let start = value.index(value.startIndex, offsetBy: from)
        let end = value.index(value.startIndex, offsetBy: to)
        guard end >= start else {
            return value
        }
        return String(value[start..<end])
    }

    private func removeDiacritics(text: String) -> String {
        // normalize Form D
        return text.decomposedStringWithCanonicalMapping.preg_replace_none_regex("\\p{Mn}", replaceto: "")
    }

    private func findKeywordsPositions(text: String, keywords: [String]) -> [(Int, Int)] {
        var positions = [(Int, Int)]()
        let cleanedText: String = self.removeDiacritics(text: text)
        let cleanedAndLowercasedText = cleanedText.localizedLowercase

        for keyword in keywords {
            let indices = cleanedAndLowercasedText.indices(of: keyword)
            if !indices.isEmpty {
                for index in indices {
                    positions.append((index, index + keyword.count))
                }
            }
        }
        // Make sure there are no overlaps when highlighting - if necessary merge the highlighted parts
        return self.sanitizePositions(occurrences: positions)
    }

    private func sanitizePositions(occurrences: [(Int, Int)]) -> [(Int, Int)] {
        if occurrences.count < 2 {
            return occurrences
        }

        // Sort from first position to last
        let sorted = occurrences.sorted { $0 < $1 }

        // Make sure there is no intersecting highlighting zones by merging them
        var noIntersections: [(Int, Int)] = []
        var previousValue: (Int, Int) = sorted.first!
        for i in 1...(sorted.count-1) {
            if (previousValue.1 >= sorted[i].0) {
                // There is an intersection, we merge the two zones
                previousValue = (previousValue.0, max(previousValue.1, sorted[i].1))
            } else {
                // no intersection
                noIntersections.append(previousValue)
                previousValue = sorted[i]
            }
        }
        noIntersections.append(previousValue)
        return noIntersections
    }

    func addKeywordHighlightingToAttributedString(stringToHighlight: NSMutableAttributedString) -> NSMutableAttributedString {
        // check if there are any keywords
        guard !self.searchQuery.isEmpty else {
            return stringToHighlight
        }

        let positions = self.findKeywordsPositions(text: stringToHighlight.string, keywords: self.searchQuery)
        if !positions.isEmpty {
            for position in positions {
                let lengthOfKeywordToHighlight = position.1-position.0
                if lengthOfKeywordToHighlight <= 0 {
                    continue
                }
                let rangeToHighlight = NSRange(location: position.0, length: lengthOfKeywordToHighlight)
                let highlightColor = UIColor.dynamic(light: ColorProvider.BrandLighten20, dark: ColorProvider.BrandLighten20)
                let highlightedAttributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key.backgroundColor: highlightColor]
                stringToHighlight.addAttributes(highlightedAttributes, range: rangeToHighlight)
            }
        }
        return stringToHighlight
    }

    private func adaptIndexingSpeed() {
        // get memory usage
        let memoryUsage: Int = self.getMemoryUsage()
        print("Memory usage: \(memoryUsage)")
        // get cpu usage
        //let cpuUsage: Double = self.getCPUUsage()
        //print("CPU usage: \(cpuUsage)")

        if memoryUsage > 20 {
            self.addTimeOutWhenIndexingAsMemoryExceeds = true
            self.indexingSpeed = 1
            self.pageSize = 1
        } else {
            // If we slow down indexing, keep it for some time
            if self.slowDownIndexingCounter > 0 {
                self.slowDownIndexingCounter = self.slowDownIndexingCounter - 1
                return
            }
            // Handle indexing speed
            if memoryUsage > 15 {
                self.indexingSpeed = 1
                self.pageSize = 10
                self.slowDownIndexingCounter = 50
            } else if memoryUsage > 10 {
                self.indexingSpeed = 5
                self.pageSize = 50//100
                self.slowDownIndexingCounter = 20
                self.addTimeOutWhenIndexingAsMemoryExceeds = false
            } else {
                if self.slowDownIndexBuilding == false {
                    self.indexingSpeed = 20//OperationQueue.defaultMaxConcurrentOperationCount
                    self.pageSize = 50//150
                    self.addTimeOutWhenIndexingAsMemoryExceeds = false
                }
            }
        }

        // Update indexing queues for immediate effect
        self.messageIndexingQueue?.maxConcurrentOperationCount = self.indexingSpeed
    }

    private func getMemoryUsage() -> Int {
        let currentAvailableMemory = self.getCurrentlyAvailableAppMemory() / 1024.0 / 1024.0
        let totalDeviceMemory = self.getTotalAvailableMemory() / 1024.0 / 1024.0
        let usedMemory: Double = totalDeviceMemory - currentAvailableMemory    // in MB
        return Int((usedMemory/totalDeviceMemory) * 100)
    }

    // Returns the total available memory on device
    func getTotalAvailableMemory() -> Double {
        var taskInfo = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size) / 4
        let _ = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
        }
        let totalMb = Float(ProcessInfo.processInfo.physicalMemory)// / 1048576.0
        return Double(totalMb)
    }

    // returns the currently available app memory
    private func getCurrentlyAvailableAppMemory() -> Double {
        var taskInfo = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size) / 4
        let result: kern_return_t = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
        }
        let usedMb = Float(taskInfo.phys_footprint)// / 1048576.0
        let totalMb = Float(ProcessInfo.processInfo.physicalMemory)// / 1048576.0
        var availableMemory: Double = 0
        if result != KERN_SUCCESS {
            availableMemory = Double(totalMb)
        } else {
            availableMemory = Double(totalMb - usedMb)
        }
        return availableMemory
    }

    func getFreeDiskSpace() -> Int64 {
        if let systemAttributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()), let freeSpace = (systemAttributes[FileAttributeKey.systemFreeSize] as? NSNumber)?.int64Value {
            return freeSpace
        } else {
            return 0
        }
    }

    // Returns the actual CPU usage in percent
    private func getCPUUsage() -> Double {
        var totalUsageOfCPU: Double = 0.0
        var threadsList: thread_act_array_t?
        var threadsCount = mach_msg_type_number_t(0)
        let threadsResult = withUnsafeMutablePointer(to: &threadsList) {
            return $0.withMemoryRebound(to: thread_act_array_t?.self, capacity: 1) {
                task_threads(mach_task_self_, $0, &threadsCount)
            }
        }
        
        if threadsResult == KERN_SUCCESS, let threadsList = threadsList {
            for index in 0..<threadsCount {
                var threadInfo = thread_basic_info()
                var threadInfoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
                let infoResult = withUnsafeMutablePointer(to: &threadInfo) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                        thread_info(threadsList[Int(index)], thread_flavor_t(THREAD_BASIC_INFO), $0, &threadInfoCount)
                    }
                }
                
                guard infoResult == KERN_SUCCESS else {
                    break
                }
                
                let threadBasicInfo = threadInfo as thread_basic_info
                if threadBasicInfo.flags & TH_FLAGS_IDLE == 0 {
                    totalUsageOfCPU = (totalUsageOfCPU + (Double(threadBasicInfo.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0))
                }
            }
        }
        
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadsList)), vm_size_t(Int(threadsCount) * MemoryLayout<thread_t>.stride))
        return totalUsageOfCPU
    }
}

extension String {
    func indices(of occurrence: String) -> [Int] {
        var indices = [Int]()
        var position = startIndex
        while let range = range(of: occurrence, range: position..<endIndex) {
            let i = distance(from: startIndex,
                             to: range.lowerBound)
            indices.append(i)
            let offset = occurrence.distance(from: occurrence.startIndex,
                                             to: occurrence.endIndex) - 1
            guard let after = index(range.lowerBound,
                                    offsetBy: offset,
                                    limitedBy: endIndex) else {
                                        break
            }
            position = index(after: after)
        }
        return indices
    }
}
