//
//  Item.swift
//  DictationIOS
//
//  Created by Jian Guo on 9/27/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
