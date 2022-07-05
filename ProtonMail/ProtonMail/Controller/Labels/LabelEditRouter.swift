//
//  LabelEditCoordinator.swift
//  Proton Mail
//
//
//  Copyright (c) 2021 Proton AG
//
//  This file is part of Proton Mail.
//
//  Proton Mail is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Proton Mail is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Proton Mail.  If not, see <https://www.gnu.org/licenses/>.

import Foundation
import UIKit

protocol CoordinatorDismissalObserver: AnyObject {
    var pendingActionAfterDismissal: (() -> Void)? { get set }

    func labelEditCoordinatorDidDismiss()
}

extension CoordinatorDismissalObserver {
    func labelEditCoordinatorDidDismiss() {
        pendingActionAfterDismissal?()
        pendingActionAfterDismissal = nil
    }
}

protocol LabelEditRouterProtocol {
    func goToParentSelect(
        label: MenuLabel?,
        labels: [MenuLabel],
        parentID: String,
        isInheritParentColorEnabled: Bool,
        isFolderColorEnabled: Bool,
        labelParentSelectDelegate: LabelParentSelectDelegate
    )
    func closeView()
}

final class LabelEditRouter: LabelEditRouterProtocol {
    private weak var navigationController: UINavigationController?
    private weak var coordinatorDismissalObserver: CoordinatorDismissalObserver?

    init(
        navigationController: UINavigationController,
        coordinatorDismissalObserver: CoordinatorDismissalObserver?
    ) {
        self.navigationController = navigationController
        self.coordinatorDismissalObserver = coordinatorDismissalObserver
    }

    func goToParentSelect(
        label: MenuLabel?,
        labels: [MenuLabel],
        parentID: String,
        isInheritParentColorEnabled: Bool,
        isFolderColorEnabled: Bool,
        labelParentSelectDelegate: LabelParentSelectDelegate
    ) {
        let parentVm = LabelParentSelectVM(
            labels: labels,
            label: label,
            useFolderColor: isFolderColorEnabled,
            inheritParentColor: isInheritParentColorEnabled,
            delegate: labelParentSelectDelegate,
            parentID: parentID
        )
        let parentVC = LabelParentSelectViewController.instance(hasNavigation: false)
        parentVC.set(viewModel: parentVm)
        navigationController?.show(parentVC, sender: nil)
    }

    func closeView() {
        navigationController?.dismiss(animated: true)
        coordinatorDismissalObserver?.labelEditCoordinatorDidDismiss()
    }
}
