//
//  KeysAPI.swift
//  ProtonMail
//
//  Created by Yanfeng Zhang on 11/11/16.
//  Copyright © 2016 ProtonMail. All rights reserved.
//

import Foundation


//MARK : get keys salt  #not in used
public class GetKeysSalts<T : ApiResponse> : ApiRequest<T> {
    
    override func getAPIMethod() -> APIService.HTTPMethod {
        return .GET
    }
    
    override public func getRequestPath() -> String {
        return KeysAPI.Path + "/salts" + AppConstants.getDebugOption
    }
    
    override public func getVersion() -> Int {
        return KeysAPI.V_GetKeysSaltsRequest
    }
}

public class KeySaltResponse : ApiResponse {
    
    var keySalts : [Dictionary<String,AnyObject>]?

    override func ParseResponse(response: Dictionary<String, AnyObject>!) -> Bool {
        self.keySalts = response["KeySalts"] as? [Dictionary<String,AnyObject>]
        return true
    }
}

/// message packages
public class PasswordAuth : Package {

    let AuthVersion : Int = 4
    let ModulusID : String! //encrypted id
    let salt : String! //base64 encoded
    let verifer : String! //base64 encoded
    
    init(modulus_id : String!, salt :String!, verifer : String!) {
        self.ModulusID = modulus_id
        self.salt = salt
        self.verifer = verifer
    }
    
    // Mark : override class functions
    func toDictionary() -> Dictionary<String,AnyObject>? {
        let out : Dictionary<String, AnyObject> = [
            "Version" : self.AuthVersion,
            "ModulusID" : self.ModulusID,
            "Salt" : self.salt,
            "Verifier" : self.verifer]
        return out
    }
}


//MARK : update user's private keys
public class UpdatePrivateKeyRequest<T : ApiResponse> : ApiRequest<T> {
    
    let clientEphemeral : String! //base64 encoded
    let clientProof : String! //base64 encoded
    let SRPSession : String! //hex encoded session id
    let tfaCode : String? // optional
    let keySalt : String! //base64 encoded need random value
    
    var userLevelKeys: Array<Key>!
    var userAddressKeys: Array<Key>!
    let orgKey : String?
    
    let auth : PasswordAuth?

    
    init(clientEphemeral: String!,
         clientProof: String!,
         SRPSession: String!,
         keySalt: String!,
         userlevelKeys: Array<Key>!,
         addressKeys: Array<Key>!,
         tfaCode : String?,
         orgKey: String?,
         
         auth: PasswordAuth?
         ) {
        self.clientEphemeral = clientEphemeral
        self.clientProof = clientProof
        self.SRPSession = SRPSession
        self.keySalt = keySalt
        self.userLevelKeys = userlevelKeys
        self.userAddressKeys = addressKeys
        
        //optional values
        self.orgKey = orgKey
        self.tfaCode = tfaCode
        self.auth = auth
    }
    
    override func toDictionary() -> Dictionary<String, AnyObject>? {
        var keysDict : [AnyObject] = [AnyObject]()
        for _key in userLevelKeys {
            if _key.is_updated {
                keysDict.append( ["ID": _key.key_id, "PrivateKey" : _key.private_key] )
            }
        }
        for _key in userAddressKeys {
            if _key.is_updated {
                keysDict.append( ["ID": _key.key_id, "PrivateKey" : _key.private_key] )
            }
        }
        
        var out : [String : AnyObject] = [
            "ClientEphemeral" : self.clientEphemeral,
            "ClientProof" : self.clientProof,
            "SRPSession": self.SRPSession,
            "KeySalt" : self.keySalt,
            "Keys" : keysDict
            ]
        
        if let code = tfaCode {
            out["TwoFactorCode"] = code
        }
        if let org_key = orgKey {
             out["OrganizationKey"] = org_key
        }
        if let auth_obj = self.auth {
            out["Auth"] = auth_obj.toDictionary()
        }
        return out
    }
    
    override func getAPIMethod() -> APIService.HTTPMethod {
        return .PUT
    }
    
    override public func getRequestPath() -> String {
        return KeysAPI.Path + "/private" + AppConstants.getDebugOption
    }
    
    override public func getVersion() -> Int {
        return KeysAPI.V_UpdatePrivateKeyRequest
    }
}
