//
//  HTTPCommon.swift
//  K2Spike
//
//  Created by Carl Brown on 4/24/17.
//
//

import Foundation

public typealias HTTPVersion = (Int, Int)

public struct HTTPHeaders {
    var storage: [String:[String]]     /* lower cased keys */
    let original: [(String, String)]   /* original casing */
  let description: String

    subscript(key: String) -> [String] {
        get {
            return storage[key] ?? []
        }
        set (value) {
            storage[key] = value
        }
    }
    
    func makeIterator() -> IndexingIterator<Array<(String, String)>> {
        return original.makeIterator()
    }

    init(_ headers: [(String, String)] = []) {
        original = headers
        description=""
        storage = [String:[String]]()
        makeIterator().forEach { (element: (String, String)) in
            let key = element.0.lowercased()
            let val = element.1
            
            var existing = storage[key] ?? []
            existing.append(val)
            storage[key] = existing
        }
    }
}

public enum Result<POSIXError, Void> {
    case success(())
    case failure(POSIXError)
    
    // MARK: Constructors
    /// Constructs a success wrapping a `closure`.
    public init(completion: ()) {
        self = .success(completion)
    }
    
    /// Constructs a failure wrapping an `POSIXError`.
    public init(error: POSIXError) {
        self = .failure(error)
    }
}

