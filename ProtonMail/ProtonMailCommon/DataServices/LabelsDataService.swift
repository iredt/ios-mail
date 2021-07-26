//
//  LabelsDataService.swift
//  ProtonMail - Created on 8/13/15.
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


import Foundation
import CoreData
import Groot
import PromiseKit
import AwaitKit
import ProtonCore_Services

enum LabelFetchType : Int {
    case all = 0
    case label = 1
    case folder = 2
    case contactGroup = 3
    case folderWithInbox = 4
    case folderWithOutbox = 5
}

class LabelsDataService: Service, HasLocalStorage {
    
    public let apiService: APIService
    private let userID : String
    private let coreDataService: CoreDataService
    private let lastUpdatedStore: LastUpdatedStoreProtocol
    private let cacheService: CacheService
    weak var viewModeDataSource: ViewModeDataSource?
    
    init(api: APIService, userID: String, coreDataService: CoreDataService, lastUpdatedStore: LastUpdatedStoreProtocol, cacheService: CacheService) {
        self.apiService = api
        self.userID = userID
        self.coreDataService = coreDataService
        self.lastUpdatedStore = lastUpdatedStore
        self.cacheService = cacheService
    }
    
    func cleanUp() -> Promise<Void> {
        return Promise { seal in
            let labelFetch = NSFetchRequest<NSFetchRequestResult>(entityName: Label.Attributes.entityName)
            labelFetch.predicate = NSPredicate(format: "%K == %@", Label.Attributes.userID, self.userID)
            let labelDeleteRequest = NSBatchDeleteRequest(fetchRequest: labelFetch)

            let contextLabelRequest = NSFetchRequest<NSFetchRequestResult>(entityName: ContextLabel.Attributes.entityName)
            contextLabelRequest.predicate = NSPredicate(format: "%K == %@", ContextLabel.Attributes.userID, self.userID)
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: contextLabelRequest)

            let moc = self.coreDataService.operationContext
            self.coreDataService.enqueue(context: moc) { (context) in
                _ = try? moc.execute(labelDeleteRequest)
                _ = try? moc.execute(deleteRequest)
                _ = context.saveUpstreamIfNeeded()
                seal.fulfill_()
            }
        }
    }
    
    static func cleanUpAll() -> Promise<Void> {
        return Promise { seal in
            let coreDataService = sharedServices.get(by: CoreDataService.self)
            let context = coreDataService.operationContext
            coreDataService.enqueue(context: context) { (context) in
                Label.deleteAll(inContext: context)
                LabelUpdate.deleteAll(inContext: context)
                ContextLabel.deleteAll(inContext: context)
                seal.fulfill_()
            }            
        }
    }

    /// Get label and folder through v4 api
    func fetchV4Labels() -> Promise<Void> {
        return Promise { seal in
            let labelReq = GetV4LabelsRequest(type: .label)
            let folderReq = GetV4LabelsRequest(type: .folder)
            
            let labelAPI: Promise<GetLabelsResponse> = self.apiService.run(route: labelReq)
            let folderAPI: Promise<GetLabelsResponse> = self.apiService.run(route: folderReq)
            // [labelAPI, folderAPI]
            _ = when(fulfilled: labelAPI, folderAPI).done { (labelRes, folderRes) in
                guard var labels = labelRes.labels,
                      var folders = folderRes.labels else {
                    let error = NSError(domain: "", code: -1,
                                        localizedDescription: LocalString._error_no_object)
                    seal.reject(error)
                    return
                }
                for (index, _) in labels.enumerated() {
                    labels[index]["UserID"] = self.userID
                }
                for (index, _) in folders.enumerated() {
                    folders[index]["UserID"] = self.userID
                }
                
                folders.append(["ID": "0"]) //case inbox   = "0"
                folders.append(["ID": "8"]) //case draft   = "8"
                folders.append(["ID": "1"]) //case draft   = "1"
                folders.append(["ID": "7"]) //case sent    = "7"
                folders.append(["ID": "2"]) //case sent    = "2"
                folders.append(["ID": "10"]) //case starred = "10"
                folders.append(["ID": "6"]) //case archive = "6"
                folders.append(["ID": "4"]) //case spam    = "4"
                folders.append(["ID": "3"]) //case trash   = "3"
                folders.append(["ID": "5"]) //case allmail = "5"
                
                let allFolders = labels + folders
                
                //save
                let context = self.coreDataService.operationContext
                self.coreDataService.enqueue(context: context) { (context) in
                    do {
                        let labels_out = try GRTJSONSerialization.objects(withEntityName: Label.Attributes.entityName, fromJSONArray: allFolders, in: context)
                        let error = context.saveUpstreamIfNeeded()
                        if error == nil {
                            if labels_out.count != allFolders.count {
                                PMLog.D("error: label insertions failed partially!")
                            }
                            seal.fulfill_()
                        } else {
                            //TODO:: error
                            seal.reject(error!)
                            PMLog.D("error: \(String(describing: error))")
                        }
                    } catch let ex as NSError {
                        seal.reject(ex)
                        PMLog.D("error: \(ex)")
                    }
                }
            }.catch { (error) in
                seal.reject(error)
            }
        }
    }

    func fetchV4ContactGroup() -> Promise<Void> {
        return Promise { seal in
            let groupRes = GetV4LabelsRequest(type: .contactGroup)
            self.apiService.exec(route: groupRes) { (_, res: GetLabelsResponse) in
                if let error = res.error {
                    seal.reject(error)
                    return
                }
                guard var labels = res.labels else {
                    let error = NSError(domain: "", code: -1,
                                        localizedDescription: LocalString._error_no_object)
                    seal.reject(error)
                    return
                }
                for (index, _) in labels.enumerated() {
                    labels[index]["UserID"] = self.userID
                }
                //save
                let context = self.coreDataService.operationContext
                self.coreDataService.enqueue(context: context) { (context) in
                    do {
                        let labels_out = try GRTJSONSerialization.objects(withEntityName: Label.Attributes.entityName, fromJSONArray: labels, in: context)
                        let error = context.saveUpstreamIfNeeded()
                        if error == nil {
                            if labels_out.count != labels.count {
                                PMLog.D("error: label insertions failed partially!")
                            }
                            seal.fulfill_()
                        } else {
                            //TODO:: error
                            seal.reject(error!)
                            PMLog.D("error: \(String(describing: error))")
                        }
                    } catch let ex as NSError {
                        seal.reject(ex)
                        PMLog.D("error: \(ex)")
                    }
                }
            }
        }
    }

    func getAllLabels(of type : LabelFetchType, context: NSManagedObjectContext) -> [Label] {
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: Label.Attributes.entityName)
        
        if type == .contactGroup && userCachedStatus.isCombineContactOn {
            // in contact group searching, predicate must be consistent with this one
            fetchRequest.predicate = NSPredicate(format: "(%K == 2)", Label.Attributes.type)
        } else {
            fetchRequest.predicate = self.fetchRequestPrecidate(type)
        }
        
        let context = context
        do {
            let results = try context.fetch(fetchRequest)
            if let results = results as? [Label] {
                return results
            } else {
                // TODO: handle error
                PMLog.D("COnversion to Label error")
            }
        } catch {
            PMLog.D("Get context failed")
        }
        
        return []
    }
    
    func fetchedResultsController(_ type : LabelFetchType) -> NSFetchedResultsController<NSFetchRequestResult>? {
        let moc = self.coreDataService.mainContext
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: Label.Attributes.entityName)
        fetchRequest.predicate = self.fetchRequestPrecidate(type)
        
        if type != .contactGroup {
            fetchRequest.sortDescriptors = [NSSortDescriptor(key: Label.Attributes.order, ascending: true)]
        } else {
            let strComp = NSSortDescriptor(key: Label.Attributes.name,
                                           ascending: true,
                                           selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
            fetchRequest.sortDescriptors = [strComp]
        }
        return NSFetchedResultsController(fetchRequest: fetchRequest, managedObjectContext: moc, sectionNameKeyPath: nil, cacheName: nil)
    }
    
    private func fetchRequestPrecidate(_ type: LabelFetchType) -> NSPredicate {
        switch type {
        case .all:
            return NSPredicate(format: "(labelID MATCHES %@) AND ((%K == 1) OR (%K == 3)) AND (%K == %@)", "(?!^\\d+$)^.+$", Label.Attributes.type, Label.Attributes.type, Label.Attributes.userID, self.userID)
        case .folder:
            return NSPredicate(format: "(labelID MATCHES %@) AND (%K == 3) AND (%K == %@)", "(?!^\\d+$)^.+$", Label.Attributes.type, Label.Attributes.userID, self.userID)
        case .folderWithInbox:
            // 0 - inbox, 6 - archive, 3 - trash, 4 - spam
            let defaults = NSPredicate(format: "labelID IN %@", [0, 6, 3, 4])
            // custom folders like in previous (LabelFetchType.folder) case
            let folder = NSPredicate(format: "(labelID MATCHES %@) AND (%K == 3) AND (%K == %@)", "(?!^\\d+$)^.+$", Label.Attributes.type, Label.Attributes.userID, self.userID)
            
            return NSCompoundPredicate(orPredicateWithSubpredicates: [defaults, folder])
        case .folderWithOutbox:
            // 7 - sent, 6 - archive, 3 - trash
            let defaults = NSPredicate(format: "labelID IN %@", [6, 7, 3])
            // custom folders like in previous (LabelFetchType.folder) case
            let folder = NSPredicate(format: "(labelID MATCHES %@) AND (%K == 3) AND (%K == %@)", "(?!^\\d+$)^.+$", Label.Attributes.type, Label.Attributes.userID, self.userID)
            
            return NSCompoundPredicate(orPredicateWithSubpredicates: [defaults, folder])
        case .label:
            return NSPredicate(format: "(labelID MATCHES %@) AND (%K == 1) AND (%K == %@)", "(?!^\\d+$)^.+$", Label.Attributes.type, Label.Attributes.userID, self.userID)
        case .contactGroup:
            return NSPredicate(format: "(%K == 2) AND (%K == %@)", Label.Attributes.type, Label.Attributes.userID, self.userID)
        }
    }
    
    func addNewLabel(_ response : [String : Any]?) {
        if var label = response {
            let context = self.coreDataService.operationContext
            context.performAndWait() {
                do {
                    label["UserID"] = self.userID
                    try GRTJSONSerialization.object(withEntityName: Label.Attributes.entityName, fromJSONDictionary: label, in: context)
                    if let error = context.saveUpstreamIfNeeded() {
                        PMLog.D("addNewLabel error: \(error)")
                    }
                } catch let ex as NSError {
                    PMLog.D("addNewLabel error: \(ex)")
                }
            }
        }
    }

    func labelFetchedController(by labelID: String) -> NSFetchedResultsController<NSFetchRequestResult> {
        let context = self.coreDataService.mainContext
        return Label.labelFetchController(for: labelID, inManagedObjectContext: context)
    }
    
    func label(by labelID : String) -> Label? {
        let context = self.coreDataService.mainContext
        return Label.labelForLabelID(labelID, inManagedObjectContext: context)
    }

    func label(name: String) -> Label? {
        let context = self.coreDataService.mainContext
        return Label.labelForLabelName(name, inManagedObjectContext: context)
    }
    
    func unreadCount(by labelID: String, userID: String? = nil) -> Promise<Int> {
        guard let viewMode = self.viewModeDataSource?.getCurrentViewMode() else {
            return Promise<Int>.value(0)
        }
        
        let mustBeSingle = [Message.Location.draft.rawValue,
                            Message.Location.sent.rawValue]
        if mustBeSingle.contains(labelID) {
            return lastUpdatedStore.unreadCount(by: labelID, userID: userID ?? self.userID, type: .singleMessage)
        }
        
        switch viewMode {
        case .conversation:
            return lastUpdatedStore.unreadCount(by: labelID, userID: userID ?? self.userID, type: .conversation)
        case .singleMessage:
            return lastUpdatedStore.unreadCount(by: labelID, userID: userID ?? self.userID, type: .singleMessage)
        }
    }

    func createNewLabel(name: String, color: String, type: PMLabelType = .label, parentID: String? = nil, notify: Bool = true, completion: ((String?, NSError?) -> Void)?) {
        let route = CreateLabelRequest(name: name, color: color, type: type, parentID: parentID, notify: notify, expanded: true)
        self.apiService.exec(route: route) { (task, response: CreateLabelRequestResponse) in
            if let err = response.error {
                completion?(nil, err.toNSError)
            } else {
                let ID = response.label?["ID"] as? String
                if let labelResponse = response.label {
                    self.cacheService.addNewLabel(serverReponse: labelResponse, completion: nil)
                }
                completion?(ID, nil)
            }
        }
    }

    func updateLabel(_ label: Label, name: String, color: String, parentID: String?, notify: Bool, completion: ((NSError?) -> Void)?) {
        let api = UpdateLabelRequest(id: label.labelID, name: name, color: color, parentID: parentID, notify: notify)
        self.apiService.exec(route: api) { (task, response: UpdateLabelRequestResponse) in
            if let err = response.error {
                completion?(err.toNSError)
            } else {
                guard let labelDic = response.label else {
                    let error = NSError(domain: "", code: -1,
                                        localizedDescription: LocalString._error_no_object)
                    completion?(error)
                    return
                }
                self.cacheService.updateLabel(serverReponse: labelDic) {
                    completion?(nil)
                }
            }
        }
    }

    
    /// Send api to delete label and remove related labels from the DB
    /// - Parameters:
    ///   - label: The label want to be deleted
    ///   - subLabelIDs: Object ids array of child labels
    ///   - completion: completion
    func deleteLabel(_ label: Label,
                     subLabelIDs: [NSManagedObjectID] = [],
                     completion: (() -> Void)?) {
        let api = DeleteLabelRequest(lable_id: label.labelID)
        self.apiService.exec(route: api) { (_, _) in

        }
        let ids = subLabelIDs + [label.objectID]
        self.cacheService.deleteLabels(objectIDs: ids) {
            completion?()
        }
    }
}
