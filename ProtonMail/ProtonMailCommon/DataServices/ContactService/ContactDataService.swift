//
//  ContactDataService.swift
//  ProtonMail
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
import Contacts
import Groot
import PromiseKit
import AwaitKit
import Crypto
import OpenPGP
import ProtonCore_DataModel
import ProtonCore_Networking
import ProtonCore_Services

typealias ContactFetchComplete = (([Contact]?, NSError?) -> Void)
typealias ContactAddComplete = (([Contact]?, NSError?) -> Void)

typealias ContactImportComplete = (([Contact]?, String) -> Void)
typealias ContactImportUpdate = ((Int) -> Void)
typealias ContactImportCancel = (() -> Bool)

typealias ContactDeleteComplete = ((NSError?) -> Void)
typealias ContactUpdateComplete = (([Contact]?, NSError?) -> Void)

protocol ContactProviderProtocol: AnyObject {
    func getAllEmails() -> [Email]
    func fetchContacts(completion: ContactFetchComplete?)
}

class ContactDataService: Service, HasLocalStorage {
    
    private let addressBookService: AddressBookService
    private let labelDataService: LabelsDataService
    private let coreDataService: CoreDataService
    private let apiService : APIService
    private let userID : String
    private var lastUpdatedStore: LastUpdatedStoreProtocol
    private let cacheService: CacheService
    private weak var queueManager: QueueManager?
    init(api: APIService, labelDataService: LabelsDataService, userID: String, coreDataService: CoreDataService, lastUpdatedStore: LastUpdatedStoreProtocol, cacheService: CacheService, queueManager: QueueManager) {
        self.userID = userID
        self.apiService = api
        self.addressBookService = AddressBookService()
        self.labelDataService = labelDataService
        self.coreDataService = coreDataService
        self.lastUpdatedStore = lastUpdatedStore
        self.cacheService = cacheService
        self.queueManager = queueManager
    }
    
    /**
     clean contact local cache
     **/
    func cleanUp() -> Promise<Void> {
        return Promise { seal in
            lastUpdatedStore.contactsCached = 0
            let context = self.coreDataService.operationContext
            self.coreDataService.enqueue(context: context) { (context) in
                let fetch1 = NSFetchRequest<NSFetchRequestResult>(entityName: Contact.Attributes.entityName)
                fetch1.predicate = NSPredicate(format: "%K == %@", Contact.Attributes.userID, self.userID)
                let request1 = NSBatchDeleteRequest(fetchRequest: fetch1)
                request1.resultType = .resultTypeObjectIDs
                if let result = try? context.execute(request1) as? NSBatchDeleteResult,
                   let objectIdArray = result.result as? [NSManagedObjectID] {
                    let changes = [NSDeletedObjectsKey: objectIdArray]
                    NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [context])
                }
                
                let fetch2 = NSFetchRequest<NSFetchRequestResult>(entityName: Email.Attributes.entityName)
                fetch2.predicate = NSPredicate(format: "%K == %@", Email.Attributes.userID, self.userID)
                let request2 = NSBatchDeleteRequest(fetchRequest: fetch2)
                request2.resultType = .resultTypeObjectIDs
                if let result = try? context.execute(request2) as? NSBatchDeleteResult,
                   let objectIdArray = result.result as? [NSManagedObjectID] {
                    let changes = [NSDeletedObjectsKey: objectIdArray]
                    NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [context])
                }
                
                let fetch3 = NSFetchRequest<NSFetchRequestResult>(entityName: LabelUpdate.Attributes.entityName)
                fetch3.predicate = NSPredicate(format: "%K == %@", LabelUpdate.Attributes.userID, self.userID)
                let request3 = NSBatchDeleteRequest(fetchRequest: fetch3)
                if let result = try? context.execute(request3) as? NSBatchDeleteResult,
                   let objectIdArray = result.result as? [NSManagedObjectID] {
                    let changes = [NSDeletedObjectsKey: objectIdArray]
                    NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [context])
                }
                
                seal.fulfill_()
            }
        }
    }
    
    static func cleanUpAll() -> Promise<Void> {
        return Promise { seal in
            let coreDataService = sharedServices.get(by: CoreDataService.self)
            let context = coreDataService.operationContext
            coreDataService.enqueue(context: context) { (context) in
                Contact.deleteAll(inContext: context)
                Email.deleteAll(inContext: context)
                seal.fulfill_()
            }
        }
    }
    
    /**
     get/build fetch results controller for contacts
     
     **/
    func resultController(isCombineContact: Bool = false) -> NSFetchedResultsController<NSFetchRequestResult>? {
        let moc = self.coreDataService.mainContext
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: Contact.Attributes.entityName)
        let strComp = NSSortDescriptor(key: Contact.Attributes.name,
                                       ascending: true,
                                       selector: #selector(NSString.caseInsensitiveCompare(_:)))
        fetchRequest.sortDescriptors = [strComp]
        
        if !isCombineContact {
            fetchRequest.predicate = NSPredicate(format: "%K == %@ AND %K == 0", Contact.Attributes.userID, self.userID, Contact.Attributes.isSoftDeleted)
        } else {
            fetchRequest.predicate = NSPredicate(format: "%K == 0", Contact.Attributes.isSoftDeleted)
        }
        return NSFetchedResultsController(fetchRequest: fetchRequest,
                                          managedObjectContext: moc,
                                          sectionNameKeyPath: Contact.Attributes.sectionName,
                                          cacheName: nil)
    }

    func contactFetchedController(by contactID: String) -> NSFetchedResultsController<NSFetchRequestResult>? {
        let moc = self.coreDataService.mainContext
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: Contact.Attributes.entityName)
        fetchRequest.predicate = NSPredicate(format: "%K == %@", Contact.Attributes.contactID, contactID)
        let strComp = NSSortDescriptor(key: Contact.Attributes.name,
                                       ascending: true,
                                       selector: #selector(NSString.caseInsensitiveCompare(_:)))
        fetchRequest.sortDescriptors = [strComp]
        return NSFetchedResultsController(fetchRequest: fetchRequest,
                                          managedObjectContext: moc,
                                          sectionNameKeyPath: nil,
                                          cacheName: nil)
    }
    
    /**
     add a new contact
     
     - Parameter cards: vcard contact data -- 4 different types
     - Parameter objectID: CoreData object ID of group label
     - Parameter completion: async add contact complete response
     **/
    func add(cards: [[CardData]], authCredential: AuthCredential?, objectID: String? = nil, completion: ContactAddComplete?) {
        let route = ContactAddRequest(cards: cards, authCredential: authCredential)
        self.apiService.exec(route: route) { [weak self] (response: ContactAddResponse) in
            guard let self = self else { return }
            let context = self.coreDataService.operationContext
            var contacts_json : [[String : Any]] = []
            var lasterror : NSError?
            let results = response.results
            context.perform {
                guard !results.isEmpty,
                      cards.count == results.count else {
                    DispatchQueue.main.async {
                        completion?(nil, lasterror)
                    }
                    return
                }
                
                for (i, res) in results.enumerated() {
                    if let error = res as? NSError {
                        lasterror = error
                        guard let objectID = objectID,
                              let managedID = self.coreDataService.managedObjectIDForURIRepresentation(objectID),
                              let managedObject = try? context.existingObject(with: managedID) else {
                            continue
                        }
                        context.delete(managedObject)
                    } else if var contact = res as? [String: Any] {
                        contact["Cards"] = cards[i].toDictionary()
                        contacts_json.append(contact)
                    }
                }
                
                if !contacts_json.isEmpty {
                    self.cacheService.addNewContact(serverResponse: contacts_json, objectID: objectID) { (contacts, error) in
                        DispatchQueue.main.async {
                            completion?(contacts, error)
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        completion?(nil, lasterror)
                    }
                }
            }
        }
    }

    /**
     update a exsiting conact
     
     - Parameter contactID: delete contact id
     - Parameter name: contact name
     - Parameter emails: contact email list
     - Parameter cards: vcard contact data -- 4 different types
     - Parameter completion: async add contact complete response
     **/
    func update(contactID: String,
                cards: [CardData], completion: ContactUpdateComplete?) {
        let api = ContactUpdateRequest(contactid: contactID, cards:cards)
        self.apiService.exec(route: api) { (task, response: ContactDetailResponse) in
            if let error = response.error {
                completion?(nil, error.toNSError)
            } else if var contactDict = response.contact {
                //api is not returning the cards data so set it use request cards data
                //check is contactDict has cards if doesnt exsit set it here
                if contactDict["Cards"] == nil {
                    contactDict["Cards"] = cards.toDictionary()
                }

                self.cacheService.updateContact(contactID: contactID, cardsJson: contactDict) { result in
                    switch result {
                    case .success(let contact):
                        completion?(contact, nil)
                    case .failure(let error):
                        completion?(nil, error)
                    }
                }
            } else {
                completion?(nil, NSError.unableToParseResponse(response))
            }
        }
    }
    
    /**
     delete a contact
     
     - Parameter contactID: delete contact id
     - Parameter completion: async delete prcess complete response
     **/
    func delete(contactID: String, completion: @escaping ContactDeleteComplete) {
        let api = ContactDeleteRequest(ids: [contactID])
        self.apiService.exec(route: api) { [weak self] (task, response) in
            guard let self = self else { return }
            let context = self.coreDataService.operationContext
            context.perform {
                if let error = response.error {
                    if error.responseCode == 13043 { //not exsit
                        self.cacheService.deleteContact(by: contactID) { _ in
                        }
                    } else {
                        let contact = Contact.contactForContactID(contactID, inManagedObjectContext: context)
                        contact?.isSoftDeleted = false
                        _ = context.saveUpstreamIfNeeded()
                    }
                    DispatchQueue.main.async {
                        completion(error.toNSError)
                    }
                    return
                }
                self.cacheService.deleteContact(by: contactID) { (error) in
                    DispatchQueue.main.async {
                        completion(error)
                    }
                }
            }
        }
    }
    
    func fetch(byEmails emails: [String], context: NSManagedObjectContext? = nil) -> Promise<[PreContact]> {
        let context = context ?? self.coreDataService.mainContext
        return Promise { seal in
            guard let fetchController = Email.findEmailsController(emails, inManagedObjectContext: context) else {
                seal.fulfill([])
                return
            }
            guard let contactEmails = fetchController.fetchedObjects as? [Email] else {
                seal.fulfill([])
                return
            }
            
            let noDetails : [Email] = contactEmails.filter { $0.managedObjectContext != nil && $0.defaults == 0 && $0.contact.isDownloaded == false && $0.userID == self.userID }
            let fetchs : [Promise<Contact>] = noDetails.map { return self.details(contactID: $0.contactID) }
            firstly {
                when(resolved: fetchs)
            }.then { (result) -> Guarantee<[Result<PreContact>]> in
                var allEmails = contactEmails
                if let newFetched = fetchController.fetchedObjects as? [Email] {
                    allEmails = newFetched
                }
                
                let details : [Email] = allEmails.filter { $0.defaults == 0 && $0.contact.isDownloaded && $0.userID == self.userID }
                var parsers : [Promise<PreContact>] = details.map {
                    return self.parseContact(email: $0.email, cards: $0.contact.getCardData())
                }
                for r in result {
                    switch r {
                    case .fulfilled(let value):
                        if let fEmail = contactEmails.first(where: { (e) -> Bool in
                            e.contactID == value.contactID
                        }) {
                            parsers.append(self.parseContact(email: fEmail.email, cards: value.getCardData()))
                        }
                    case .rejected:
                        break
                    }
                }
                return when(resolved: parsers)
            }.then { contacts -> Promise<[PreContact]> in
                var sucessed : [PreContact] = [PreContact]()
                for c in contacts {
                    switch c {
                    case .fulfilled(let value):
                        sucessed.append(value)
                    case .rejected:
                        break
                    }
                }
                return .value(sucessed)
            }.done { result in
                seal.fulfill(result)
            }.catch(policy: .allErrors) { error in
                seal.reject(error)
            }
        }
    }
    
    func parseContact(email : String, cards: [CardData]) -> Promise<PreContact> {
        return Promise { seal in
            async {
                for c in cards {
                    switch c.type {
                    case .SignedOnly:
                        if let vcard = PMNIEzvcard.parseFirst(c.data) {
                            let emails = vcard.getEmails()
                            for e in emails {
                                if email == e.getValue() {
                                    let group = e.getGroup();
                                    let encrypt = vcard.getPMEncrypt(group)
                                    let sign = vcard.getPMSign(group)
                                    let isSign = sign?.getValue() ?? "false" == "true" ? true : false
                                    let keys = vcard.getKeys(group)
                                    let isEncrypt = encrypt?.getValue() ?? "false" == "true" ? true : false
                                    let schemeType = vcard.getPMScheme(group)
                                    let isMime = schemeType?.getValue() ?? "pgp-mime" == "pgp-mime" ? true : false
                                    let mimeType = vcard.getPMMimeType(group)
                                    let pt = mimeType?.getValue()
                                    let plainText = pt ?? "text/html" == "text/html" ? false : true
                                    
                                    var firstKey : Data?
                                    var pubKeys : [Data] = []
                                    for key in keys {
                                        let kg = key.getGroup()
                                        if kg == group {
                                            let kp = key.getPref()
                                            let value = key.getBinary() //based 64 key
                                            if let isExpired = value.isPublicKeyExpired(), !isExpired {
                                                pubKeys.append(value)
                                                if kp == 1 || kp == Int32.min {
                                                    firstKey = value
                                                }
                                            }
                                        }
                                    }
                                    return seal.fulfill(PreContact(email: email,
                                                                   pubKey: firstKey, pubKeys: pubKeys,
                                                                   sign: isSign, encrypt: isEncrypt,
                                                                   mime: isMime, plainText: plainText))
                                }
                            }
                        }
                    default:
                        break
                        
                    }
                }
                //TODO::need to improve the error part
                seal.reject(NSError.badResponse())
            }
           

        }
    }
    
    /**
     get all contacts from server
     
     - Parameter completion: async complete response
     **/
    fileprivate var isFetching : Bool = false
    fileprivate var retries : Int = 0
    func fetchContacts(completion: ContactFetchComplete?) {
        if lastUpdatedStore.contactsCached == 1 || isFetching {
            completion?(nil, nil)
            return
        }
        
        if self.retries > 3 {
            lastUpdatedStore.contactsCached = 0
            self.isFetching = false;
            self.retries = 0
            completion?(nil, nil)
            return
        }
        
        self.isFetching = true
        self.retries = self.retries + 1

        async {
            do {
                // fetch contacts, without their respective emails
                var currentPage = 0
                var fetched = -1
                let pageSize = 1000
                var loop = 1
                var total = 0
                while (true) {
                    if loop <= 0 || fetched >= total {
                        break
                    }
                    loop = loop - 1
                    
                    let response: ContactsResponse = try `await`(self.apiService.run(route: ContactsRequest(page: currentPage, pageSize: pageSize)))
                    if response.error == nil {
                        let contacts = response.contacts //TODO:: fix me set userID
                        if fetched == -1 {
                            fetched = contacts.count
                            total = response.total
                            loop = (total / pageSize) - (total % pageSize == 0 ? 1 : 0)
                        } else {
                            fetched = fetched + contacts.count
                        }
                        self.cacheService.addNewContact(serverResponse: contacts, shouldFixName: true) { (_, error) in
                            if let err = error {
                                DispatchQueue.main.async {
                                    err.alertErrorToast()
                                }
                            }
                        }
                    }
                }

                // fetch contact groups  //TDOO:: this fetch could be removed.
                // TODO: if I don't manually store the labels first, the record won't be saved automatically? (cascade)
                self.labelDataService.fetchV4ContactGroup().cauterize()

                // fetch contact emails
                currentPage = 0
                fetched = -1
                loop = 1
                total = 0
                while (true) {
                    if loop <= 0 || fetched >= total {
                        break
                    }
                    loop = loop - 1
                    let contactsRes: ContactEmailsResponse = try `await`(self.apiService.run(route: ContactEmailsRequest(page: currentPage,
                                                                                                                       pageSize: pageSize)))
                    if contactsRes.error == nil {
                        currentPage = currentPage + 1
                        let contactsArray = contactsRes.contacts
                        if fetched == -1 {
                            fetched = contactsArray.count
                            total = contactsRes.total
                            loop = (total / pageSize) - (total % pageSize == 0 ? 1 : 0)
                            if loop == 0 && fetched < total {
                                loop = loop + 1
                            }
                        } else {
                            fetched = fetched + contactsArray.count
                        }
                        self.cacheService.addNewContact(serverResponse: contactsArray, shouldFixName: true) { (_, error) in
                            if let err = error {
                                DispatchQueue.main.async {
                                    err.alertErrorToast()
                                }
                            }
                        }
                    }
                }
                self.lastUpdatedStore.contactsCached = 1
                self.isFetching = false
                self.retries = 0

                completion?(nil, nil)

            } catch let ex as NSError {
                self.lastUpdatedStore.contactsCached = 0
                self.isFetching = false;

                {
                    completion?(nil, ex)
                } ~> .main
            }
        }
    }
    
    /**
     get contact full details
     
     - Parameter contactID: contact id
     - Parameter completion: async complete response
     **/
    func details(contactID: String) -> Promise<Contact> {
        return Promise { seal in
            let api = ContactDetailRequest(cid: contactID)
            self.apiService.exec(route: api) { (task, response: ContactDetailResponse) in
                if let error = response.error {
                    seal.reject(error)
                } else if let contactDict = response.contact {
                    self.cacheService.updateContactDetail(serverResponse: contactDict) { (contact, error) in
                        if let err = error {
                            seal.reject(err)
                        } else if let c = contact {
                            seal.fulfill(c)
                        } else {
                            fatalError()
                        }
                    }
                } else {
                    seal.reject(NSError.unableToParseResponse(response))
                }
            }
        }
    }
    
    
    /// Only call from the main thread
    func allEmails() -> [Email] {
        let context = self.coreDataService.mainContext
        return self.allEmailsInManagedObjectContext(context)
    }

    func allAccountEmails() -> [Email] {
        let context = coreDataService.mainContext
        return allEmailsInManagedObjectContext(context).filter { $0.userID == userID }
    }
    
    private func allEmailsInManagedObjectContext(_ context: NSManagedObjectContext) -> [Email] {
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: Email.Attributes.entityName)
        do {
            if let emails = try context.fetch(fetchRequest) as? [Email] {
                return emails
            }
        } catch {
        }
        return []
    }
    
    private func allEmailsInManagedObjectContext(_ context: NSManagedObjectContext, isContactCombine: Bool) -> [Email] {
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: Email.Attributes.entityName)
        let predicate = isContactCombine ? nil : NSPredicate(format: "%K == %@", Email.Attributes.userID, self.userID)
        fetchRequest.predicate = predicate
        do {
            if let emails = try context.fetch(fetchRequest) as? [Email] {
                return emails
            }
        } catch {
        }
        return []
    }
    
    /**
     The function that checks if the current dest contactVO (emailID) is an e2e encrypted
     
     - Parameters:
     - model: ContactPickerModelProtocol
     - progress: the closure that contains the actions required before and during the email status is being checked
     - complete: the closure that contains the actions required after the email status is checked
     */
    func lockerCheck(model: ContactPickerModelProtocol,
                     message: Message? = nil,
                     progress: () -> Void,
                     complete: ((UIImage?, Int) -> Void)?) {
        guard let c = model as? ContactVO else {
            complete?(nil, -1)
            return
        }
        
        guard let email = model.displayEmail else {
            complete?(nil, -1)
            return
        }
        
        progress()
        
        let context = self.coreDataService.mainContext // VALIDATE
        async {
            let getEmail: Promise<KeysResponse> = self.apiService.run(route: UserEmailPubKeys(email: email))
            let getContact = self.fetch(byEmails: [email], context: context)
            when(fulfilled: getEmail, getContact).done { keyRes, contacts in
                if keyRes.recipientType == 1 {
                    if let contact = contacts.first, contact.firstPgpKey != nil {
                        c.pgpType = .internal_trusted_key
                    } else {
                        c.pgpType = .internal_normal
                    }
                } else {
                    if let contact = contacts.first, contact.firstPgpKey != nil {
                        if contact.encrypt {
                            c.pgpType = .pgp_encrypt_trusted_key
                        } else if contact.sign {
                            c.pgpType = .pgp_signed
                            if let pwd = message?.password, pwd != "" {
                                c.pgpType = .eo
                            }
                        }
                    } else {
                        if let pwd = message?.password, pwd != "" {
                            c.pgpType = .eo
                        } else {
                            c.pgpType = .none
                        }
                    }
                }
                complete?(c.pgpType.lockImage, c.pgpType.rawValue)
            }.catch(policy: .allErrors) { _ in
                complete?(nil, -1)
            }
        }
    }
}

// MRAK: Queue related
extension ContactDataService {
    func queueAddContact(cardDatas: [CardData], name: String, emails: [ContactEditEmail]) -> NSError? {
        let context = self.coreDataService.operationContext
        let userID = self.userID
        var error: NSError?
        context.performAndWait { [weak self] in
            guard let self = self else { return }
            do {
                let contact = try Contact.makeTempContact(context: context,
                                                          userID: userID,
                                                          name: name,
                                                          cardDatas: cardDatas,
                                                          emails: emails)
                if let err = context.saveUpstreamIfNeeded() {
                    error = err
                    return
                }
                let objectID = contact.objectID.uriRepresentation().absoluteString
                let action: MessageAction = .addContact(objectID: objectID,
                                                        cardDatas: cardDatas)
                let task = QueueManager.Task(messageID: "", action: action, userID: userID, dependencyIDs: [], isConversation: false)
                _ = self.queueManager?.addTask(task)
            } catch {
                return
            }
        }
        return error
    }

    func queueUpdate(objectID: NSManagedObjectID, contactID: String, cardDatas: [CardData], newName: String, emails: [ContactEditEmail], completion: ContactUpdateComplete?) {
        let context = self.coreDataService.operationContext
        context.perform { [weak self] in
            guard let self = self else { return }
            do {
                guard let contactInContext = try context.existingObject(with: objectID) as? Contact else {
                    let error = NSError(domain: "", code: -1,
                                        localizedDescription: LocalString._error_no_object)
                    completion?(nil, error)
                    return
                }
                contactInContext.cardData = try cardDatas.toJSONString()
                contactInContext.name = newName
                if let emailObjects = contactInContext.emails.allObjects as? [Email] {
                    for emailObject in emailObjects {
                        context.delete(emailObject)
                    }
                }
                // These temp emails will be removed when process real api response
                // CacheService > updateContact(contactID:...)
                _ = emails.map { $0.makeTempEmail(context: context, contact: contactInContext) }
                if let error = context.saveUpstreamIfNeeded() {
                    completion?(nil, error)
                } else {
                    let idString = objectID.uriRepresentation().absoluteString
                    let action: MessageAction = .updateContact(objectID: idString,
                                                               cardDatas: cardDatas)
                    let task = QueueManager.Task(messageID: "", action: action, userID: self.userID, dependencyIDs: [], isConversation: false)
                    _ = self.queueManager?.addTask(task)
                    completion?(nil, nil)
                }
            } catch {
                completion?(nil, error as NSError)
            }
        }
    }

    func queueDelete(objectID: NSManagedObjectID, completion: ContactDeleteComplete?) {
        let context = self.coreDataService.operationContext
        context.perform {
            do {
                guard let contactInContext = try context.existingObject(with: objectID) as? Contact else {
                    let error = NSError(domain: "", code: -1,
                                        localizedDescription: LocalString._error_no_object)
                    completion?(error)
                    return
                }
                contactInContext.isSoftDeleted = true
                if let error = context.saveUpstreamIfNeeded() {
                    completion?(error as NSError)
                    return
                }
                let idString = objectID.uriRepresentation().absoluteString
                let action: MessageAction = .deleteContact(objectID: idString)
                let task = QueueManager.Task(messageID: "", action: action, userID: self.userID, dependencyIDs: [], isConversation: false)
                _ = self.queueManager?.addTask(task)
                completion?(nil)
            } catch {
                completion?(error as NSError)
            }
        }
    }
}

//// MARK: AddressBook contact extension
extension ContactDataService {
    typealias ContactVOCompletionBlock = ((_ contacts: [ContactVO], _ error: Error?) -> Void)
    
    func allContactVOs() -> [ContactVO] {
        allEmails()
            .filter { $0.userID == userID }
            .map { ContactVO(id: $0.contactID, name: $0.name, email: $0.email, isProtonMailContact: true) }
    }
    
    func getContactVOs(_ completion: @escaping ContactVOCompletionBlock) {
        self.processContacts(lastError: nil, completion: completion)
    }

    func getContactVOsFromPhone(_ completion: @escaping ContactVOCompletionBlock) {
        guard addressBookService.hasAccessToAddressBook() else {
            addressBookService.requestAuthorizationWithCompletion { granted, error in
                if granted {
                    completion(self.addressBookService.contacts(), nil)
                } else {
                    completion([], error)
                }
            }
            return
        }
        completion(addressBookService.contacts(), nil)
    }
    
    private func processContacts(lastError: Error?, completion: @escaping ContactVOCompletionBlock) {
        struct ContactWrapper: Hashable {
            let contact: ContactVO
            let lastUsedTime: Date?
        }

        DispatchQueue.global(qos: DispatchQoS.QoSClass.userInitiated).async {
            var contacts: [ContactWrapper] = []
            
            // merge address book and core data contacts
            let context = self.coreDataService.operationContext // VALIDATE
            context.performAndWait() {
                let emailsCache = self.allEmailsInManagedObjectContext(context,
                                                                       isContactCombine: userCachedStatus.isCombineContactOn)
                var pm_contacts: [ContactWrapper] = []
                for email in emailsCache {
                    if email.managedObjectContext != nil {
                        let contact = ContactVO(id: email.contactID, name: email.name, email: email.email, isProtonMailContact: true)
                        pm_contacts.append(ContactWrapper(contact: contact, lastUsedTime: email.lastUsedTime))
                    }
                }
                contacts.append(contentsOf: pm_contacts)
            }

            // sort rule: 1. lastUsedTime 2. name 3. email
            contacts.sort(by: { (first: ContactWrapper, second: ContactWrapper) -> Bool in
                if let t1 = first.lastUsedTime, let t2 = second.lastUsedTime {
                    let result = t1.compare(t2)
                    if result == .orderedAscending {
                        return false
                    } else if result == .orderedDescending {
                        return true
                    }
                }

                if first.lastUsedTime != nil && second.lastUsedTime == nil {
                    return true
                }

                if second.lastUsedTime != nil && first.lastUsedTime == nil {
                    return false
                }

                if first.contact.name.lowercased() != second.contact.name.lowercased() {
                    return first.contact.name.lowercased() < second.contact.name.lowercased()
                } else {
                    return first.contact.email.lowercased() < second.contact.email.lowercased()
                }
            })

            // Remove the duplicated items
            var set = Set<ContactVO>()
            var filteredResult = [ContactVO]()
            for wrapper in contacts {
                if !set.contains(wrapper.contact) {
                    set.insert(wrapper.contact)
                    filteredResult.append(wrapper.contact)
                }
            }
            
            DispatchQueue.main.async {
                completion(filteredResult, lastError)
            }
        }
    }
}

extension ContactDataService: ContactProviderProtocol {
    func getAllEmails() -> [Email] {
        return allAccountEmails()
    }
}
