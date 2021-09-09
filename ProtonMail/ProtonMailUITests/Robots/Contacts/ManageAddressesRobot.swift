//
//  ManageAddressesRobot.swift
//  ProtonMailUITests
//
//  Created by denys zelenchuk on 06.10.20.
//  Copyright © 2020 ProtonMail. All rights reserved.
//

import pmtest

fileprivate struct id {
    static func contactCellIdentifier(_ email: String) -> String { return "ContactGroupEditViewCell.\(email)" }
    static let backButtonIdentifier = LocalString._contact_groups_add
}

/**
 ManageAddressesRobot class contains actions and verifications for Adding a Contact to Group.
 */
class ManageAddressesRobot: CoreElements {

    func addContactToGroup(_ withEmail: String) -> AddContactGroupRobot {
        return clickContact(withEmail).back()
    }
    
    func clickContact(_ withEmail: String) -> ManageAddressesRobot {
        cell(id.contactCellIdentifier(withEmail)).tap()
        return self
    }

    private func back() -> AddContactGroupRobot {
        button(id.backButtonIdentifier).tap()
        return AddContactGroupRobot()
    }
}
