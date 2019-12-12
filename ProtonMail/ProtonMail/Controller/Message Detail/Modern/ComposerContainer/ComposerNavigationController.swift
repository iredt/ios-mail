//
//  ComposerNavigationController.swift
//  ProtonMail - Created on 14/07/2019.
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

class ComposerNavigationController: UINavigationController {
    
}

@available(iOS, deprecated: 13.0, message: "iOS 13 restores state via Deeplinkable conformance")
extension ComposerNavigationController: UIViewControllerRestoration {
    override func applicationFinishedRestoringState() {
        super.applicationFinishedRestoringState()
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        self.restorationIdentifier = String(describing: ComposerNavigationController.self)
        self.restorationClass = ComposerNavigationController.self
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if self.viewControllers.isEmpty {
            self.dismiss(animated: false, completion: nil)
        }
    }
    
    static func viewController(withRestorationIdentifierPath identifierComponents: [String], coder: NSCoder) -> UIViewController? {
        let navigation = ComposerNavigationController()
        navigation.restorationIdentifier = String(describing: ComposerNavigationController.self)
        navigation.restorationClass = ComposerNavigationController.self
        return navigation
    }
}
