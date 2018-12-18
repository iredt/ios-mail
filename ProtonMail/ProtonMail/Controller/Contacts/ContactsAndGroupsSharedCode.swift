//
//  ContactsAndGroupsSharedCode.swift
//  ProtonMail - Created on 2018/9/13.
//
//
//  The MIT License
//
//  Copyright (c) 2018 Proton Technologies AG
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.


import Foundation

class ContactsAndGroupsSharedCode: ProtonMailViewController
{
    var navigationItemRightNotEditing: [UIBarButtonItem]? = nil
    var navigationItemLeftNotEditing: [UIBarButtonItem]? = nil
    private var addBarButtonItem: UIBarButtonItem!
    private var importBarButtonItem: UIBarButtonItem!
    
    let kAddContactSugue = "toAddContact"
    let kAddContactGroupSugue = "toAddContactGroup"
    let kSegueToImportView = "toImportContacts"
    let kToUpgradeAlertSegue = "toUpgradeAlertSegue"
    
    var isOnMainView = true {
        didSet {
            if isOnMainView {
                self.tabBarController?.tabBar.isHidden = false
            } else {
                self.tabBarController?.tabBar.isHidden = true
            }
        }
    }
    
    func prepareNavigationItemRightDefault() {
        self.addBarButtonItem = UIBarButtonItem.init(barButtonSystemItem: .add,
                                                     target: self,
                                                     action: #selector(self.addButtonTapped))
        self.importBarButtonItem = UIBarButtonItem.init(image: UIImage.init(named: "mail_attachment-closed"),
                                                        style: .plain,
                                                        target: self,
                                                        action: #selector(self.importButtonTapped))
        
        let rightButtons: [UIBarButtonItem] = [self.importBarButtonItem, self.addBarButtonItem]
        self.navigationItem.setRightBarButtonItems(rightButtons, animated: true)
        
        navigationItemLeftNotEditing = navigationItem.leftBarButtonItems
        navigationItemRightNotEditing = navigationItem.rightBarButtonItems
    }
    
    @objc private func addButtonTapped() {
        /// set title
        let alertController = UIAlertController(title: LocalString._contacts_action_select_an_option,
                                                message: nil,
                                                preferredStyle: .actionSheet)
        
        /// set options
        alertController.addAction(UIAlertAction(title: LocalString._contacts_add_contact,
                                                style: .default,
                                                handler: {
                                                    (action) -> Void in
                                                    self.addContactTapped()
        }))
        
        alertController.addAction(UIAlertAction(title: LocalString._contact_groups_add,
                                                style: .default,
                                                handler: {
                                                    (action) -> Void in
                                                    self.addContactGroupTapped()
        }))
        
        /// set cancel
        alertController.addAction(UIAlertAction(title: LocalString._general_cancel_button,
                                                style: .cancel,
                                                handler: nil))
        
        /// present
        alertController.popoverPresentationController?.barButtonItem = addBarButtonItem
        alertController.popoverPresentationController?.sourceRect = self.view.frame
        self.present(alertController, animated: true, completion: nil)
    }
    
    @objc private func importButtonTapped() {
        let alertController = UIAlertController(title: LocalString._contacts_action_select_an_option,
                                                message: nil,
                                                preferredStyle: .actionSheet)
        
        alertController.addAction(UIAlertAction(title: LocalString._contacts_upload_contacts, style: .default, handler: { (action) -> Void in
            self.navigationController?.popViewController(animated: true)
            
            let alertController = UIAlertController(title: LocalString._contacts_title,
                                                    message: LocalString._upload_ios_contacts_to_protonmail,
                                                    preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: LocalString._general_confirm_action,
                                                    style: .default,
                                                    handler: { (action) -> Void in
                                                        self.performSegue(withIdentifier: self.kSegueToImportView,
                                                                          sender: self)
            }))
            alertController.addAction(UIAlertAction(title: LocalString._general_cancel_button, style: .cancel, handler: nil))
            self.present(alertController, animated: true, completion: nil)
        }))
        
        /// set cancel
        alertController.addAction(UIAlertAction(title: LocalString._general_cancel_button,
                                                style: .cancel,
                                                handler: nil))
        
        /// present
        alertController.popoverPresentationController?.barButtonItem = addBarButtonItem
        alertController.popoverPresentationController?.sourceRect = self.view.frame
        self.present(alertController, animated: true, completion: nil)
    }
    
    @objc private func addContactTapped() {
        self.performSegue(withIdentifier: kAddContactSugue, sender: self)
    }
    
    @objc private func addContactGroupTapped() {
        if sharedUserDataService.isPaidUser() {
            self.performSegue(withIdentifier: kAddContactGroupSugue, sender: self)
        } else {
            self.performSegue(withIdentifier: kToUpgradeAlertSegue, sender: self)
        }
    }
}
