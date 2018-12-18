//
//  PasswordUtils.swift
//  ProtonMail - Created on 9/28/16.
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

enum PasswordError: Error {
    case hashEmpty
    case hashEmptyEncode
    case hashSizeWrong
}

final class PasswordUtils {
    static func getHashedPwd(_ authVersion: Int , password: String, username: String, decodedSalt : Data, decodedModulus : Data) -> Data? {
        var hashedPassword : Data?
        switch authVersion {
        case 0:
            hashedPassword = PasswordUtils.hashPasswordVersion0(password, username: username, modulus: decodedModulus)
            break
        case 1:
            hashedPassword = PasswordUtils.hashPasswordVersion1(password, username: username, modulus: decodedModulus)
            break
        case 2:
            hashedPassword = PasswordUtils.hashPasswordVersion2(password, username: username, modulus: decodedModulus)
            break
        case 3:
            hashedPassword = PasswordUtils.hashPasswordVersion3(password, salt: decodedSalt, modulus: decodedModulus)
            break
        case 4:
            hashedPassword = PasswordUtils.hashPasswordVersion4(password, salt: decodedSalt, modulus: decodedModulus)
            break
        default: break
        }
        return hashedPassword
    }
    
    
    static func CleanUserName(_ username : String) -> String {
        return username.preg_replace("_|\\.|-", replaceto: "").lowercased()
    }
    
    fileprivate static func bcrypt(_ password :String, salt :String) throws -> String {
        let real_salt = "$2a$10$" + salt
        let out_hash = PMNBCrypt(password: password, salt: real_salt)
        if !out_hash.isEmpty {
            let size = out_hash.count
            if size > 4 {
                let index = out_hash.index(out_hash.startIndex, offsetBy: 4)
                return "$2y$" + String(out_hash[index...])
            }
        }
        
        //backup plan when native bcrypt return empty string
        if let out = JKBCrypt.hashPassword(password, withSalt: real_salt), !out.isEmpty {
            let size = out.count
            if size > 4 {
                let index = out.index(out.startIndex, offsetBy: 4)
                return "$2y$" + String(out[index...])
            } else {
                throw PasswordError.hashSizeWrong
            }
        }
        throw PasswordError.hashEmpty
    }
    
    fileprivate static func bcrypt_byte(_ password :String, salt :String) throws -> Data? {
        let b = try bcrypt(password, salt: salt)
        if let stringData = b.data(using: String.Encoding.utf8, allowLossyConversion: false) {
            return stringData
        }
        throw PasswordError.hashEmptyEncode
    }
    
    fileprivate static func bcrypt_string(_ password :String, salt :String) throws -> String {
        let b = try bcrypt(password, salt: salt)
        return b
    }
    
    
    static func expandHash(_ input : Data) -> Data {
        return PMNSrpClient.expandHash(input);
    }
    
    static func getMailboxPassword(_ password : String, salt : Data) -> String {
        let byteArray = NSMutableData()
        byteArray.append(salt)
        let source = NSData(data: byteArray as Data) as Data
        let encodedSalt = JKBCrypt.based64DotSlash(source)
        do {
            let out = try bcrypt_string(password, salt: encodedSalt)
            let index = out.index(out.startIndex, offsetBy: 29)
            let outStr = String(out[index...])
            return outStr
        } catch PasswordError.hashEmpty {
            // check error
        } catch PasswordError.hashSizeWrong {
            // check error
        } catch {
            // check error
        }
        return ""
        
    }
    
    static func hashPasswordVersion4(_ password : String, salt : Data, modulus : Data) -> Data? {
        return hashPasswordVersion3(password, salt: salt, modulus: modulus);
    }
    
    static func hashPasswordVersion3(_ password : String, salt : Data, modulus : Data) -> Data? {
        let byteArray = NSMutableData()
        byteArray.append(salt)
        if let encodedSalt = "proton".data(using: String.Encoding.utf8, allowLossyConversion: false) {
            byteArray.append(encodedSalt)
        }
        
        let source = NSData(data: byteArray as Data) as Data
        let encodedSalt = JKBCrypt.based64DotSlash(source)
        
        do {
            if let out = try bcrypt_byte(password, salt: encodedSalt) {
                let outArray = NSMutableData()
                outArray.append(out)
                outArray.append(modulus)
                return expandHash(NSData(data: outArray as Data) as Data)
            }
        } catch PasswordError.hashEmpty {
            // check error
        } catch PasswordError.hashSizeWrong {
            // check error
        } catch {
            // check error
        }
        return nil
    }

    static func hashPasswordVersion2(_ password : String, username : String, modulus : Data) -> Data? {
        return hashPasswordVersion1(password, username: CleanUserName(username), modulus: modulus);
    }
    
    static func hashPasswordVersion1(_ password : String, username : String, modulus : Data) -> Data? {
        let un = username.lowercased()
        let salt = un.md5
        do {
            if let out = try bcrypt_byte(password, salt: salt) {
                let byteArray = NSMutableData()
                byteArray.append(out)
                byteArray.append(modulus)
                return expandHash(NSData(data: byteArray as Data) as Data)
            }
        } catch PasswordError.hashEmpty {
            // check error
        } catch PasswordError.hashSizeWrong {
            // check error
        } catch {
            // check error
        }
        return nil
    }
    
    static func hashPasswordVersion0(_ password : String,   username : String,  modulus: Data ) -> Data? {
        //need check password size
        if let prehashed = password.sha512_byte {
            let encoded = prehashed.base64EncodedString(options: NSData.Base64EncodingOptions(rawValue: 0))
            return hashPasswordVersion1(encoded, username: username, modulus: modulus);
        }
        return nil
    }
    
}
