

import Foundation

extension Dictionary where Value : Equatable {
    func allKeysForValue(_ val : Value) -> [Key] {
        return self.filter { $0.value == val }.map { $0.key }
    }

    public init(_ seq: Zip2Sequence<[Key], [Value]>) {
        self.init()
        for (k,v) in seq {
            self[k] = v
        }
    }
}

func += <K, V> (left: inout [K:V], right: [K:V]) {
    for (k, v) in right {
        left.updateValue(v, forKey: k)
    }
}
