// Copyright (c) 2021 Proton Technologies AG
//
// This file is part of ProtonMail.
//
// ProtonMail is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// ProtonMail is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with ProtonMail. If not, see https://www.gnu.org/licenses/.

import ProtonCore_UIFoundations
import UIKit

class SettingsEncryptedSearchDownloadedMessagesViewController: ProtonMailTableViewController, ViewModelProtocol, CoordinatedNew {
    internal var viewModel: SettingsEncryptedSearchDownloadedMessagesViewModel!
    internal var coordinator: SettingsDeviceCoordinator?
    
    struct Key  {
        static let cellHeightMessageHistory: CGFloat = 108.0
        static let cellHeightStorageLimit: CGFloat = 116.0
        static let cellHeightStorageUsage: CGFloat = 96.0
        static let footerHeight: CGFloat = 48.0
        static let headerHeightFirstCell: CGFloat = 32.0
        static let headerHeight: CGFloat = 8.0
        static let headerCell: String = "header_cell"
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        self.updateTitle()

        self.view.backgroundColor = ColorProvider.BackgroundSecondary
        self.tableView.register(UITableViewHeaderFooterView.self, forHeaderFooterViewReuseIdentifier: Key.headerCell)
        self.tableView.register(ThreeLinesTableViewCell.self)
        self.tableView.register(ButtonTableViewCell.self)
        self.tableView.register(SliderTableViewCell.self)

        self.tableView.estimatedSectionFooterHeight = Key.footerHeight
        self.tableView.sectionFooterHeight = UITableView.automaticDimension
        self.tableView.estimatedRowHeight = Key.cellHeightMessageHistory
        self.tableView.rowHeight = UITableView.automaticDimension
    }

    func getCoordinator() -> CoordinatorNew? {
        return self.coordinator
    }

    func set(coordinator: SettingsDeviceCoordinator) {
        self.coordinator = coordinator
    }

    func set(viewModel: SettingsEncryptedSearchDownloadedMessagesViewModel) {
        self.viewModel = viewModel
    }

    private func updateTitle() {
        self.title = LocalString._encrypted_search_downloaded_messages
    }
}

extension SettingsEncryptedSearchDownloadedMessagesViewController {
    override func numberOfSections(in tableView: UITableView) -> Int {
        return viewModel.sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return 1
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if section == 0 {
            return Key.headerHeightFirstCell
        }
        return Key.headerHeight
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let headerView = UIView()
        headerView.backgroundColor = ColorProvider.BackgroundSecondary
        headerView.translatesAutoresizingMaskIntoConstraints = false

        if section == 0 {
            NSLayoutConstraint.activate([
                headerView.heightAnchor.constraint(equalToConstant: Key.headerHeightFirstCell)
            ])
        } else {
            NSLayoutConstraint.activate([
                headerView.heightAnchor.constraint(equalToConstant: Key.headerHeight)
            ])
        }

        return headerView
    }
    
    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        if section == 2 {
            return Key.footerHeight
        }
        return CGFloat.leastNormalMagnitude
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let section = indexPath.section

        let eSection = self.viewModel.sections[section]
        switch eSection {
        case .messageHistory:
            return Key.cellHeightMessageHistory
        case .storageLimit:
            return Key.cellHeightStorageLimit
        case .storageUsage:
            return Key.cellHeightStorageUsage
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell{
        let section = indexPath.section
        let eSection = self.viewModel.sections[section]
        switch eSection {
        case .messageHistory:
            let cell = tableView.dequeueReusableCell(withIdentifier: ThreeLinesTableViewCell.CellID, for: indexPath)
            if let threeLineCell = cell as? ThreeLinesTableViewCell {
                let usersManager: UsersManager = sharedServices.get(by: UsersManager.self)
                let userID: String = (usersManager.firstUser?.userInfo.userId)!
                let oldestIndexedMessage: String = "Oldest message: " + EncryptedSearchIndexService.shared.getOldestMessageInSearchIndex(for: userID)
                var downloadStatus: String = ""
                var icon: String = "ic-check"
                if EncryptedSearchService.shared.state == .partial {
                    icon = "ic-exclamation-circle"
                    downloadStatus = LocalString._settings_message_history_status_partial_downloaded
                    threeLineCell.bottomLabel.textColor = ColorProvider.NotificationError
                } else {
                    icon = "ic-check"
                    downloadStatus = LocalString._settings_message_history_status_all_downloaded
                }
                threeLineCell.configCell(eSection.title, oldestIndexedMessage, downloadStatus, icon)
            }
            return cell
        case .storageLimit:
            let cell = tableView.dequeueReusableCell(withIdentifier: SliderTableViewCell.CellID, for: indexPath)
            if let sliderCell = cell as? SliderTableViewCell {
                let factor: Float = 1 //update if MB or GB
                let representation: String = factor == 1 ? "MB" : "GB"
                
                let sliderValue: Float = self.viewModel.storageLimit * factor
                let freeDiskSpaceInMB: Float = Float(EncryptedSearchIndexService.shared.getFreeDiskSpace().asInt64!)/Float(1_000_000)
                let maxValue: Float = freeDiskSpaceInMB * factor
                let minValue: Float = self.viewModel.minStorageSize * factor
                
                let bottomLinePrefix: String = "Current selection: "
                let bottomLine: String = bottomLinePrefix + String(sliderValue) + representation
                sliderCell.configCell(eSection.title, bottomLine, currentValue: sliderValue, maxValue: maxValue, minValue: minValue){_,newSliderValue in
                    self.viewModel.storageLimit = newSliderValue
                    sliderCell.bottomLabel.text = bottomLinePrefix + String(newSliderValue) + representation

                    //update storageusage row with storage limit
                    let path: IndexPath = IndexPath.init(row: 0, section: SettingsEncryptedSearchDownloadedMessagesViewModel.SettingsSection.storageUsage.rawValue)
                    UIView.performWithoutAnimation {
                        self.tableView.reloadRows(at: [path], with: .none)
                    }
                }
            }
            return cell
        case .storageUsage:
            let cell = tableView.dequeueReusableCell(withIdentifier: ButtonTableViewCell.CellID, for: indexPath)
            if let buttonCell = cell as? ButtonTableViewCell {
                let usersManager: UsersManager = sharedServices.get(by: UsersManager.self)
                let userID: String = (usersManager.firstUser?.userInfo.userId)!
                let sizeOfIndex: String = EncryptedSearchIndexService.shared.getSizeOfSearchIndex(for: userID).asString
                let storageLimit: Float = self.viewModel.storageLimit
                let bottomLine = sizeOfIndex + " of " + String(storageLimit) + " GB"
                buttonCell.configCell(eSection.title, bottomLine, "Clear"){
                    self.showAlertDeleteDownloadedMessages()
                }
            }
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: Key.headerCell)
        header?.contentView.subviews.forEach { $0.removeFromSuperview() }
        header?.contentView.backgroundColor = ColorProvider.BackgroundSecondary

        if let headerCell = header {
            let eSection = self.viewModel.sections[section]
            switch eSection {
            case .messageHistory, .storageLimit:
                break
            case .storageUsage:
                let textLabel = UILabel()
                textLabel.numberOfLines = 0
                textLabel.translatesAutoresizingMaskIntoConstraints = false
                textLabel.attributedText = NSAttributedString(string: eSection.foot, attributes: FontManager.CaptionWeak)
                headerCell.contentView.addSubview(textLabel)

                NSLayoutConstraint.activate([
                    textLabel.topAnchor.constraint(equalTo: headerCell.contentView.topAnchor, constant: 8),
                    textLabel.bottomAnchor.constraint(equalTo: headerCell.contentView.bottomAnchor, constant: -8),
                    textLabel.leadingAnchor.constraint(equalTo: headerCell.contentView.leadingAnchor, constant: 16),
                    textLabel.trailingAnchor.constraint(equalTo: headerCell.contentView.trailingAnchor, constant: -16)
                ])
                break
            }
        }
        return header
    }

    func showAlertDeleteDownloadedMessages() {
        //create the alert
        let alert = UIAlertController(title: LocalString._encrypted_search_delete_messages_alert_title, message: LocalString._encrypted_search_delete_messages_alert_message, preferredStyle: UIAlertController.Style.alert)
        //add the buttons
        alert.addAction(UIAlertAction(title: LocalString._encrypted_search_delete_messages_alert_button_cancel, style: UIAlertAction.Style.cancel){ (action:UIAlertAction!) in
            self.tableView.reloadData()
        })
        alert.addAction(UIAlertAction(title: LocalString._encrypted_search_delete_messages_alert_button_delete, style: UIAlertAction.Style.destructive){ (action:UIAlertAction!) in
            //delete search index
            EncryptedSearchService.shared.deleteSearchIndex()
            self.navigationController?.popViewController(animated: true)
        })

        //show alert
        self.present(alert, animated: true, completion: nil)
    }

    /*private func calculateStorageSize() -> (value: Float, representation: String) {
        let freeDiskSpace: Float = Float(EncryptedSearchIndexService.shared.getFreeDiskSpace().asInt64!)
        //print("free disk space: \(freeDiskSpace)")
        if freeDiskSpace/Float(1_000_000_000) > 1 {
            //gigabyte
            return (freeDiskSpace/Float(1_000_000), "GB")
        }else if freeDiskSpace/Float(1_000_000) > 1 {
            //mega byte
            return (freeDiskSpace/Float(1_000), "MB")
        } else if freeDiskSpace/Float(1_000) > 1 {
            //kilo byte
            return (freeDiskSpace/Float(1), "KB")
        } else {
            //byte
            return (Float(0), "B")
        }
    }*/
}
