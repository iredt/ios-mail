//
//  LabelsAndFoldersRobot.swift
//  ProtonMailUITests
//
//  Created by denys zelenchuk on 11.10.20.
//  Copyright © 2020 ProtonMail. All rights reserved.
//

import pmtest

fileprivate struct id {
    static let addFolderButtonIdentifier = "LabelsViewController.addFolderButton"
    static let newLabel = "New label"
    static let folderNameTextFieldIdentifier = "LabelEditViewController.newLabelInput"
    static let createButtonIdentifier = "LabelEditViewController.applyButton"
    static let closeButtonIdentifier = "LabelEditViewController.closeButton"
    static let keyboardDoneIdentifier = "Done"
    static let deleteButtonIdentifier = LocalString._general_delete_action
    static func labelFolderCellIdentifier(_ name: String) -> String { return "LabelTableViewCell.\(name)" }
    static func selectLabelFolderButtonIdentifier(_ name: String) -> String { return "\(name).selectStatusButton" }
    static func editLabelFolderButtonIdentifier(_ name: String) -> String { return "\(name).editButton" }
    static let colorCollectionViewIdentifier = "LabelEditViewController.collectionView"
}

/**
 LabelsAndFoldersRobot class represents Labels/Folders view.
 */
class AccountSettingsLabelsAndFoldersRobot: CoreElements {
    
    var verify = Verify()

    func addFolder() -> AddFolderLabelRobot {
        button(id.addFolderButtonIdentifier).tap()
        return AddFolderLabelRobot()
    }
    
    func addLabel() -> AddFolderLabelRobot {
        staticText(id.newLabel).tap()
        return AddFolderLabelRobot()
    }
    
    func deleteFolderLabel(_ name: String) -> AccountSettingsRobot {
        return selectFolderLabel(name)
            .delete()
    }
    
    func editFolderLabel(_ folderName: String) -> AddFolderLabelRobot {
        button(id.editLabelFolderButtonIdentifier(folderName)).tap()
        return AddFolderLabelRobot()
    }
    
    func close() -> AccountSettingsRobot {
        button(id.closeButtonIdentifier).tap()
        return AccountSettingsRobot()
    }
    
    private func selectFolderLabel(_ name: String) -> AccountSettingsLabelsAndFoldersRobot {
        button(id.selectLabelFolderButtonIdentifier(name)).tap()
        return self
    }
    
    private func delete() -> AccountSettingsRobot {
        button(id.deleteButtonIdentifier).tap()
        return AccountSettingsRobot()
    }
    
    /**
     AddFolderLabelRobot class represents  modal state with color selection and Label/Folder name text field.
     */
    class AddFolderLabelRobot: CoreElements {
        
        func createFolderLabel(_ name: String) -> AccountSettingsLabelsAndFoldersRobot {
            return setFolderLabelName(name)
                .done()
                .create()
        }
        
        private func setFolderLabelName(_ name: String) -> AddFolderLabelRobot {
            textField(id.folderNameTextFieldIdentifier).typeText(name)
            return self
        }
        
        func editFolderLabelName(_ name: String) -> AddFolderLabelRobot {
            textField(id.folderNameTextFieldIdentifier).clearText().typeText(name)
            return AddFolderLabelRobot()
        }
        
        func selectFolderColorByIndex(_ index: Int) -> AddFolderLabelRobot {
            collectionView(id.colorCollectionViewIdentifier).onChild(cell().byIndex(index)).tap()
            return AddFolderLabelRobot()
        }
        
        func done() -> AddFolderLabelRobot {
            button(id.keyboardDoneIdentifier).tap()
            return self
        }
        
        func create() -> AccountSettingsLabelsAndFoldersRobot {
            button(id.createButtonIdentifier).tap()
            return AccountSettingsLabelsAndFoldersRobot()
        }
    }
    
    /**
     Contains all the validations that can be performed by LabelsAndFoldersRobot.
     */
    class Verify: CoreElements {
        
        func folderLabelExists(_ name: String) {
            cell(id.labelFolderCellIdentifier(name)).wait().checkExists()
        }
        
        func folderLabelDeleted(_ name: String) {
            cell(id.labelFolderCellIdentifier(name)).waitUntilGone()
        }
    }
}
