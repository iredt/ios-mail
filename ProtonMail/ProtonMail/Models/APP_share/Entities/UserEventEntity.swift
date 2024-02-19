// Copyright (c) 2023 Proton Technologies AG
//
// This file is part of Proton Mail.
//
// Proton Mail is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Proton Mail is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Proton Mail. If not, see https://www.gnu.org/licenses/.

import Foundation

struct UserEventEntity {
    let userID: UserID
    let eventID: String
    let updateTime: Date?

    init(userEvent: UserEvent) {
        self.userID = .init(userEvent.userID)
        self.eventID = userEvent.eventID
        self.updateTime = userEvent.updateTime
    }

    init(userID: UserID, eventID: String, updateTime: Date?) {
        self.userID = userID
        self.eventID = eventID
        self.updateTime = updateTime
    }
}
