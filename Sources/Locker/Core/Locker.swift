//
//  Locker.swift
//  Locker
//
//  Created by Zvonimir Medak on 19.10.2021..
//  Copyright © 2021 Infinum. All rights reserved.
//

import Foundation
import UIKit

@objcMembers
public class Locker: NSObject {

    // MARK: - Public properties

    public static var userDefaults: UserDefaults? {
        get {
            return currentUserDefaults == nil ? UserDefaults.standard : currentUserDefaults
        }
        set {
            currentUserDefaults = newValue ?? .standard
        }
    }

    /// Is `true` if the settings changed since Your last calling this method or last saving in Keychain
    public static var biometricsSettingsDidChange: Bool {
        LockerHelpers.biometricsSettingsChanged
    }

    public static var isRunningFromTheSimulator: Bool {
    #if targetEnvironment(simulator)
        return true
    #else
        return false
    #endif
    }

    /// Gives you an available biomertry type (none, touchID, faceID) for Your device
    public static var supportedBiometricsAuthentication: BiometricsType {
        LockerHelpers.supportedBiometricAuthentication
    }

    /// Gives you an enrolled biometry type (none, touchID, faceID) for Your device
    public static var configuredBiometricsAuthentication: BiometricsType {
        LockerHelpers.configuredBiometricsAuthentication
    }

    /// When enabled, if the device is not present on the local list of supported devices,
    /// it syncs the list with a list from the server and writes it down to the local JSON file.
    public static var enableDeviceListSync: Bool = false {
        didSet {
            guard enableDeviceListSync else { return }
            LockerHelpers.fetchNewDeviceList()
        }
    }

    // MARK: - Private properties

    private static var currentUserDefaults: UserDefaults?

    // MARK: - Handle secrets (store, delete, fetch)

    /**
    Sets a `secret` for a specified unique identifier

    - Parameters:
     - secret: the value you want to store to UserDefaults
     - uniqueIdentifier: the identifier you want to use when retrieving the value
     - completed: closure that is called upon finished secret storage. If the error occurs upon storing,
        info will be passed through the completion block
     */
    public static func setSecret(
        _ secret: String,
        for uniqueIdentifier: String,
        completed: ((LockerError?) -> Void)? = nil
    ) {
    #if targetEnvironment(simulator)
        Locker.userDefaults?.set(secret, forKey: uniqueIdentifier)
    #else
        setSecretForDevice(secret, for: uniqueIdentifier, completion: { error in
            completed?(error)
        })
    #endif
    }

    /**
     Retrieves a `secret` for a specified unique identifier.
     If the `secret` was found, success block will be called, otherwise the failure block's called.

     - Parameters:
        - uniqueIdentifier: the indetifier for which you want to retrieve the `secret`
        - operationPrompt: the identifier which will be used for a reason why LAContext is used
        - success: closure which retrives the secret for the specified unique identifier
        - failure: closure which retrieves the failure status if the secret wasn't found
     */
    @objc(retreiveCurrentSecretForUniqueIdentifier:operationPrompt:success:failure:)
    public static func retrieveCurrentSecret(
        for uniqueIdentifier: String,
        operationPrompt: String,
        success: ((String) -> Void)?,
        failure: ((OSStatus) -> Void)?
    ) {

    #if targetEnvironment(simulator)
        let simulatorSecret = Locker.userDefaults?.string(forKey: uniqueIdentifier)
        guard let simulatorSecret = simulatorSecret else {
            failure?(errSecItemNotFound)
            return
        }
        success?(simulatorSecret)
    #else
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: LockerHelpers.keyKeychainServiceName,
            kSecAttrAccount: LockerHelpers.keyKeychainAccountNameForUniqueIdentifier(uniqueIdentifier),
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
            kSecUseOperationPrompt: operationPrompt
        ]

        DispatchQueue.global(qos: .default).async {
            var dataTypeRef: CFTypeRef?

            let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
            if status == errSecSuccess {
                guard let resultData = dataTypeRef as? Data,
                      let result = String(data: resultData, encoding: .utf8) else {
                          failure?(errSecItemNotFound)
                          return
                      }

                DispatchQueue.main.async {
                    success?(result)
                }
            } else {
                failure?(status)
            }
        }
    #endif
    }

    /**
     Deletes the stored `secret` for the specified unique identifier

     - Parameter uniqueIdentifier: the identifier for which you want to delete the `secret`
     */
    @objc(deleteSecretForUniqueIdentifier:)
    public static func deleteSecret(for uniqueIdentifier: String) {

    #if targetEnvironment(simulator)
        Locker.userDefaults?.removeObject(forKey: uniqueIdentifier)
    #else
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: LockerHelpers.keyKeychainServiceName,
            kSecAttrAccount: LockerHelpers.keyKeychainAccountNameForUniqueIdentifier(uniqueIdentifier)
        ]

        DispatchQueue.global(qos: .default).async {
            SecItemDelete(query as CFDictionary)
        }
    #endif
    }
}

// MARK: - Additional helpers

public extension Locker {

    /// Checks if the flag for biometrics usage for the specified unique identifier has been set
    ///
    /// - Parameter uniqueIdentifier: the unique identifier for which You want to retrieve the value
    ///
    /// - Returns: a boolean value for the specified unique identifier
    /// which represents if it should use biometric authentication
    @objc(shouldUseAuthenticationWithBiometricsForUniqueIdentifier:)
    static func shouldUseAuthenticationWithBiometrics(for uniqueIdentifier: String) -> Bool {
        return Locker.userDefaults?.bool(
            forKey: LockerHelpers.keyBiometricsIDActivatedForUniqueIdentifier(uniqueIdentifier)
        ) ?? false
    }

    /// Sets a new value in User Deafults which represents if it should use
    /// biometric authentication for the specified unique identifier
    ///
    /// - Parameters:
    ///     - shouldUse: boolean value which represents if it should use the biometric authentication
    ///     - uniqueIdentifier: the specified indentifier for which to save the new value in user defaults
    @objc(setShouldUseAuthenticationWithBiometrics:forUniqueIdentifier:)
    static func setShouldUseAuthenticationWithBiometrics(_ shouldUse: Bool, for uniqueIdentifier: String) {
        if !shouldUse && Locker.shouldAddSecretToKeychainOnNextLogin(for: uniqueIdentifier) {
            Locker.setShouldAddSecretToKeychainOnNextLogin(false, for: uniqueIdentifier)
        }
        Locker.userDefaults?.set(
            shouldUse,
            forKey: LockerHelpers.keyBiometricsIDActivatedForUniqueIdentifier(uniqueIdentifier)
        )
    }

    /// Checks if the user asked to use biometric authentication for the specified unique identifier
    ///
    /// - Parameter uniqueIdentifier: the unique identifier for which You want to retrieve the value
    ///
    /// - Returns: a boolean value for the specified unique identifier which represents
    /// if the user asked to use biometrics authentication
    @objc(didAskToUseAuthenticationWithBiometricsForUniqueIdentifier:)
    static func didAskToUseAuthenticationWithBiometrics(for uniqueIdentifier: String) -> Bool {
        Locker.userDefaults?.bool(
            forKey: LockerHelpers.keyDidAskToUseBiometricsIDForUniqueIdentifier(uniqueIdentifier)
        ) ?? false
    }

    /// Sets a new value in User Deafults which represents if the user asked
    /// to use biometric authentication  for the specified unique identifier
    ///
    /// - Parameters:
    ///     - useAuthenticationBiometrics: boolean value which represents if the user asked for biometric authentication
    ///     - uniqueIdentifier: the specified indentifier for which to save the new value in user defaults
    @objc(setDidAskToUseAuthenticationWithBiometrics:forUniqueIdentifier:)
    static func setDidAskToUseAuthenticationWithBiometrics(
        _ useAuthenticationBiometrics: Bool,
        for uniqueIdentifier: String
    ) {
        Locker.userDefaults?.set(
            useAuthenticationBiometrics,
            forKey: LockerHelpers.keyDidAskToUseBiometricsIDForUniqueIdentifier(uniqueIdentifier)
        )
    }

    /// Checks if it should add the `secret` to Keychain on the next login
    ///
    /// - Parameter uniqueIdentifier: the unique identifier for which You want to retrieve the value
    ///
    /// - Returns: a boolean value for the specified unique identifier which represents
    /// if the `secret` should be saved to Keychain on the next login
    @objc(shouldAddSecretToKeychainOnNextLoginForUniqueIdentifier:)
    static func shouldAddSecretToKeychainOnNextLogin(for uniqueIdentifier: String) -> Bool {
        Locker.userDefaults?.bool(
            forKey: LockerHelpers.keyShouldAddSecretToKeychainOnNextLoginForUniqueIdentifier(uniqueIdentifier)
        ) ?? false
    }

    /// Sets a new value in User Defaults which represents if it should save the `secret` to Keychain
    /// on the next login for the specified unique identifier
    ///
    /// - Parameters:
    ///     - shouldAdd: boolean value which represents if `secret` should be saved to Keychain on the next login
    ///     - uniqueIdentifier: the specified indentifier for which to save the new value
    @objc(setShouldAddSecretToKeychainOnNextLogin:forUniqueIdentifier:)
    static func setShouldAddSecretToKeychainOnNextLogin(_ shouldAdd: Bool, for uniqueIdentifier: String) {
        Locker.userDefaults?.set(
            shouldAdd,
            forKey: LockerHelpers.keyShouldAddSecretToKeychainOnNextLoginForUniqueIdentifier(uniqueIdentifier)
        )
    }
}

// MARK: - Data reset

public extension Locker {

    /// Removes all values which were currently stored for the specified unique identifier

    /// - Parameter uniqueIdentifier: the identifier for which to remove values
    @objc(resetForUniqueIdentifier:)
    static func reset(for uniqueIdentifier: String) {
        Locker.userDefaults?.removeObject(
            forKey: LockerHelpers.keyDidAskToUseBiometricsIDForUniqueIdentifier(uniqueIdentifier)
        )
        Locker.userDefaults?.removeObject(
            forKey: LockerHelpers.keyShouldAddSecretToKeychainOnNextLoginForUniqueIdentifier(uniqueIdentifier)
        )
        Locker.userDefaults?.removeObject(
            forKey: LockerHelpers.keyBiometricsIDActivatedForUniqueIdentifier(uniqueIdentifier)
        )
        Locker.deleteSecret(for: uniqueIdentifier)
    }
}

internal extension Locker {
    static func setSecretForDevice(
        _ secret: String,
        for uniqueIdentifier: String,
        completion: ((LockerError?) -> Void)? = nil
    ) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: LockerHelpers.keyKeychainServiceName,
            kSecAttrAccount: LockerHelpers.keyKeychainAccountNameForUniqueIdentifier(uniqueIdentifier)
        ]

        DispatchQueue.global(qos: .default).async {
            // First delete the previous item if it exists
            SecItemDelete(query as CFDictionary)

            // Then store it
            let errorRef: UnsafeMutablePointer<Unmanaged<CFError>?>? = nil
            var flags: SecAccessControlCreateFlags
            if #available(iOS 11.3, *) {
                flags = .biometryCurrentSet
            } else {
                flags = .touchIDCurrentSet
            }
            let sacObject = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault,
                kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                flags,
                errorRef
            )

            guard let sacObject = sacObject, errorRef == nil, let secretData = secret.data(using: .utf8) else {
                if errorRef != nil {
                    completion?(.accessControl)
                } else {
                    completion?(.invalidData)
                }
                return
            }
            addSecItem(for: uniqueIdentifier, secretData, sacObject: sacObject, completion: completion)
        }
    }

    private static func addSecItem(
        for uniqueIdentifier: String,
        _ secretData: Data, sacObject: SecAccessControl,
        completion: ((LockerError?) -> Void)? = nil
    ) {
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: LockerHelpers.keyKeychainServiceName,
            kSecAttrAccount: LockerHelpers.keyKeychainAccountNameForUniqueIdentifier(uniqueIdentifier),
            kSecValueData: secretData,
            kSecUseAuthenticationUI: false,
            kSecAttrAccessControl: sacObject
        ]

        DispatchQueue.global(qos: .default).async {
            SecItemAdd(attributes as CFDictionary, nil)

            // Store current LA policy domain state
            LockerHelpers.storeCurrentLAPolicyDomainState()
            completion?(nil)
        }
    }
}