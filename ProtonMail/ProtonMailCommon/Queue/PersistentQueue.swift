//
//  PersistentQueue.swift
//  ProtonMail
//
//
// Copyright 2015 ArcTouch, Inc.
// All rights reserved.
//
// This file, its contents, concepts, methods, behavior, and operation
// (collectively the "Software") are protected by trade secret, patent,
// and copyright laws. The use of the Software is governed by a license
// agreement. Disclosure of the Software to third parties, in any form,
// in whole or in part, is expressly prohibited except as authorized by
// the license agreement.
//

import Foundation

@objcMembers class PersistentQueue: NSObject {
    
    struct Key {
        static let elementID = "elementID"
        static let object = "object"
    }
    
    fileprivate var queueURL: URL
    fileprivate let queueName: String
    
    dynamic fileprivate(set) var queue: [Any] {
        didSet {
            DispatchQueue.global(qos: DispatchQoS.QoSClass.background).sync { () -> Void in
                let data = NSKeyedArchiver.archivedData(withRootObject: self.queue)
                do {
                    try data.write(to: self.queueURL, options: [.atomic])
                    self.queueURL.excludeFromBackup()
                } catch {
                    PMLog.D("Unable to save queue: \(self.queue as NSArray)\n to \(self.queueURL.absoluteString)")
                }
            }
        }
    }
    
    /// Number of objects in the Queue
    var count: Int {
        return self.queue.count
    }
    
    func queueArray() -> [Any]
    {
        return self.queue
    }
    
    init(queueName: String) {
        self.queueName = "\(QueueConstant.queueIdentifer).\(queueName)"
        #if APP_EXTENSION
        // we do not want to persist queue in Extensions so far, cuz if queue contains some crashy/memory abusing operation it will continue crashing forever. We'll just put the url outside our sandbox to OS will not let us save the file
        // TODO: persist queue in CoreData so the app will have access to all the queues, but every Extension process - only to his own
        self.queueURL = URL(string: "/")!
        #else
        self.queueURL = FileManager.default.applicationSupportDirectoryURL.appendingPathComponent(self.queueName)
        #endif
        if let data = try? Data(contentsOf: queueURL) {
            self.queue = (NSKeyedUnarchiver.unarchiveObject(with: data) ?? []) as! [Any]
        }
        else {
            self.queue = []
        }
        
        super.init()
    }
    
    func add (_ uuid: UUID, object: NSCoding) -> UUID {
        let element = [Key.elementID : uuid, Key.object : object] as [String : Any]
        self.queue.append(element)
        return uuid
    }
    
    /// Adds an object to the persistent queue.
    func add(_ object: NSCoding) -> UUID {
        let uuid = UUID()
        return self.add(uuid, object: object)
    }
    
    /// Clears the persistent queue.
    func clear() {
        queue.removeAll()
    }
    
    /// Returns the next item in the persistent queue or nil, if the queue is empty.
    func next() -> (elementID: UUID, object: Any)? {
        if let element = queue.first as? [String : Any] {
            return (element[Key.elementID] as! UUID, element[Key.object]!)
        }
        return nil
    }
    
    /// Removes an element from the persistent queue
    func remove(_ elementID: UUID) -> Bool {
        for (index, element) in queue.enumerated() {
            if let elementDict = element as? [String : Any], let kID = elementDict[Key.elementID] as? UUID{
                if kID == elementID {
                    queue.remove(at: index)
                    return true
                }
            }
        }
        return false
    }
}
