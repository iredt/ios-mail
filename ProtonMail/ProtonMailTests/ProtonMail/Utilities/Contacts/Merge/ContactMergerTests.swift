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

import ProtonCoreDataModel
import ProtonCoreCrypto
import ProtonCoreUtilities
@testable import ProtonMail
import XCTest
import VCard

final class ContactMergerTests: XCTestCase {
    private var sut: ContactMerger!

    override func tearDown() {
        super.tearDown()
        sut = nil
    }

    func testMerge_withAutoImport_itReturnsContactEntityWithMergedData() throws {
        sut = try ContactMerger(
            deviceContact: deviceContact,
            protonContact: contactEntity,
            userKeys: userKeys,
            mailboxPassphrase: SyncContactTestUtils.passphrase
        )

        let result = try sut.merge(strategy: AutoImportStrategy()).contactEntity
        
        XCTAssertTrue(result != nil)
        XCTAssertEqual(result?.cardDatas.count, 2)


        // signed vCard
        let signedVCard: String! = result?.cardDatas.filter({ $0.type == .SignedOnly }).first?.data
        let pmniCard1 = PMNIEzvcard.parseFirst(signedVCard)

        XCTAssertEqual(pmniCard1?.getFormattedName()?.getValue(), "Kathy Bell")

        let emails = pmniCard1?.getEmails().map { $0.getValue() }
        XCTAssertEqual(emails, ["kate-bell@mac.com", "kate-bell@proton.me"])


        // encrypted vCard

        let encryptedVCard: String! = result?.cardDatas.filter({ $0.type == .SignAndEncrypt }).first?.data
        let decryptedVCard = try encryptedVCard.decryptMessageWithSingleKeyNonOptional(
            ArmoredKey(value: userKeys.first!.privateKey),
            passphrase: SyncContactTestUtils.passphrase
        )
        let pmniCard2 = PMNIEzvcard.parseFirst(decryptedVCard)

        XCTAssertEqual(pmniCard2?.getStructuredName()?.getGiven(), "Kathy")
        XCTAssertEqual(pmniCard2?.getStructuredName()?.getFamily(), "Bell")

        let phoneNumbers = pmniCard2?.getTelephoneNumbers().map { $0.getText() }
        XCTAssertEqual(phoneNumbers, ["(555) 564-8583", "(415) 555-3695", "555-478-7672"])

        let addresses = pmniCard2?.getAddresses()
        XCTAssertEqual(addresses?.count, 2)

        let organization = pmniCard2?.getOrganizations().map({ $0.getValue() }).first
        XCTAssertEqual(organization, "Proton")

        let nickname = pmniCard2?.getNickname().map({ $0.getNickname() })
        XCTAssertEqual(nickname, "KAT")
    }
}

extension ContactMergerTests {

    var deviceContact: DeviceContact {
        DeviceContact(
            identifier: .init(uuid: "", emails: []),
            fullName: nil,
            vCard:
            """
            BEGIN:VCARD
            VERSION:4.0
            FN;PREF=1:Kathy Bell
            X-ABADR:us
            TEL;TYPE="HOME,VOICE,pref";PREF=1:555-478-7672
            N:Bell;Kathy;;;
            NICKNAME:KAT
            ORG:Proton;
            ADR;TYPE="HOME,pref";PREF=1:;;332 Laguna Street;Corte Madera;CA;94925;USA
            PRODID;TYPE=text;VALUE=TEXT:pm-ez-vcard 0.0.1
            EMAIL;TYPE="HOME";PREF=1:kate-bell@proton.me
            UID:AB211C5F-9EC9-429F-9466-B9382FF61035
            END:VCARD
            """
        )
    }

    var contactEntity: ContactEntity {
        ContactEntity.make(cardData: SyncContactTestUtils.contactCardData)
    }

    var userKeys: [Key] {
        [Key(keyID: "1", privateKey: SyncContactTestUtils.privateKey)]
    }
}
