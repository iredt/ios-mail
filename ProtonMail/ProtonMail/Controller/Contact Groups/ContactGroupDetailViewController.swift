//
//  ContactGroupDetailViewController.swift
//  ProtonMail
//
//  Created by Chun-Hung Tseng on 2018/9/10.
//  Copyright © 2018 ProtonMail. All rights reserved.
//

import UIKit
import PromiseKit

class ContactGroupDetailViewController: ProtonMailViewController, ViewModelProtocol {

    var viewModel: ContactGroupDetailViewModel!
    
    @IBOutlet weak var groupNameLabel: UILabel!
    @IBOutlet weak var groupDetailLabel: UILabel!
    @IBOutlet weak var groupImage: UIImageView!
    @IBOutlet weak var tableView: UITableView!
    @IBOutlet weak var sendButton: UIButton!
    
    let kToContactGroupEditSegue = "toContactGroupEditSegue"
    
    let kContactGroupViewCellIdentifier = "ContactGroupEditCell"
    private let kToComposerSegue = "toComposer"
    private let kToUpgradeAlertSegue = "toUpgradeAlertSegue"
    
    func setViewModel(_ vm: Any) {
        viewModel = vm as! ContactGroupDetailViewModel
    }
    
    func inactiveViewModel() {}
    
    @IBAction func sendButtonTapped(_ sender: UIButton) {
        if sharedUserDataService.isPaidUser() {
            self.performSegue(withIdentifier: kToComposerSegue, sender: (ID: viewModel.getGroupID(), name: viewModel.getName()))
        } else {
            self.performSegue(withIdentifier: kToUpgradeAlertSegue, sender: self)
        }
    }
    
    @IBAction func editButtonTapped(_ sender: UIBarButtonItem) {
        if sharedUserDataService.isPaidUser() == false {
            self.performSegue(withIdentifier: kToUpgradeAlertSegue, sender: self)
            
            return
        }
        
        performSegue(withIdentifier: kToContactGroupEditSegue,
                     sender: self)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.title = LocalString._contact_groups_detail_view_title
        
        prepareTable()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        firstly {
            () -> Promise<Bool> in
            
            ActivityIndicatorHelper.showActivityIndicator(at: self.view)
            return self.viewModel.reload()
            }.ensure {
                ActivityIndicatorHelper.hideActivityIndicator(at: self.view)
            }.done {
                (isDeleted) in
                
                if isDeleted {
                    self.navigationController?.popViewController(animated: true)
                } else {
                    self.refresh()
                }
            }
    }
    
    private func refresh() {
        prepareHeader()
        tableView.reloadData()
    }

    private func prepareHeader() {
        groupNameLabel.text = viewModel.getName()
        
        groupDetailLabel.text = viewModel.getTotalEmailString()
        
        groupImage.setupImage(tintColor: UIColor.white,
                              backgroundColor: UIColor.init(hexString: viewModel.getColor(),
                                                            alpha: 1))
        
        if let image = sendButton.imageView?.image {
            sendButton.imageView?.contentMode = .center
            sendButton.imageView?.image = UIImage.resize(image: image, targetSize: CGSize.init(width: 20, height: 20))
        }
    }
    
    private func prepareTable() {
        tableView.register(UINib(nibName: "ContactGroupEditViewCell", bundle: Bundle.main),
                           forCellReuseIdentifier: kContactGroupViewCellIdentifier)
        tableView.noSeparatorsBelowFooter()
        
        tableView.allowsSelection = false
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == kToContactGroupEditSegue {
            let contactGroupEditViewController = segue.destination.children[0] as! ContactGroupEditViewController
            
            if let sender = sender as? ContactGroupDetailViewController,
                let viewModel = sender.viewModel {
                sharedVMService.contactGroupEditViewModel(contactGroupEditViewController,
                                                          state: .edit,
                                                          groupID: viewModel.getGroupID(),
                                                          name: viewModel.getName(),
                                                          color: viewModel.getColor(),
                                                          emailIDs: viewModel.getEmailIDs())
            } else {
                // TODO: handle error
                fatalError("Can't prepare for the contact group edit view")
            }
        } else if segue.identifier == kToComposerSegue {
            let destination = segue.destination.children[0] as! ComposeEmailViewController
            
            if let result = sender as? (String, String) {
                let contactGroupVO = ContactGroupVO.init(ID: result.0, name: result.1)
                contactGroupVO.selectAllEmailFromGroup()
                sharedVMService.newDraft(vmp: destination, with: contactGroupVO)
            }
        } else if segue.identifier == kToUpgradeAlertSegue {
            let popup = segue.destination as! UpgradeAlertViewController
            popup.delegate = self
            sharedVMService.upgradeAlert(contacts: popup)
            self.setPresentationStyleForSelfController(self,
                                                       presentingController: popup,
                                                       style: .overFullScreen)
        }
    }
}

extension ContactGroupDetailViewController: UpgradeAlertVCDelegate {
    func goPlans() {
        self.navigationController?.dismiss(animated: false, completion: {
            NotificationCenter.default.post(name: .switchView,
                                            object: MenuItem.servicePlan)
        })
    }
    
    func learnMore() {
        UIApplication.shared.openURL(URL(string: "https://protonmail.com/support/knowledge-base/paid-plans/")!)
    }
    
    func cancel() {
        
    }
}

extension ContactGroupDetailViewController: UITableViewDataSource
{
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return viewModel.getTotalEmails()
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 && viewModel.getTotalEmails() > 0 {
            return LocalString._menu_contacts_title
        }
        return nil
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: kContactGroupViewCellIdentifier,
                                                 for: indexPath) as! ContactGroupEditViewCell
        
        let ret = viewModel.getEmail(at: indexPath)
        cell.config(emailID: ret.emailID,
                    name: ret.name,
                    email: ret.email,
                    queryString: "",
                    state: .detailView)
        
        return cell
    }
}
