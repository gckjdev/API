//
//  ServerTime.swift
//  API
//
//  Created by 王义川 on 15/7/13.
//  Copyright © 2015年 肇庆市创威发展有限公司. All rights reserved.
//

import Foundation


extension NSHTTPURLResponse {
    private static let dateFormatter: NSDateFormatter = {
        let dateFormatter = NSDateFormatter()
        dateFormatter.locale = NSLocale(localeIdentifier: "GMT")
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return dateFormatter
        }()
    
    public var serverTime: NSDate? {
        guard let serverTimeString = self.allHeaderFields["Date"] as? String else {
            return nil
        }
        return NSHTTPURLResponse.dateFormatter.dateFromString(serverTimeString)
    }
}

public class ServerTime {
    public static var sharedInstance = ServerTime(offset: 0)
    
    public let offset: NSTimeInterval
    public var time: NSDate {
        return NSDate(timeIntervalSinceNow:offset)
    }
    
    public init(offset:NSTimeInterval) {
        self.offset = offset
    }
    
    public convenience init(date: NSDate) {
        self.init(offset:date.timeIntervalSinceNow)
    }
}

extension ServerTime {
    public func dateSinceNow(timeIntervalSinceNow: NSTimeInterval) -> NSDate {
        return NSDate(timeInterval: timeIntervalSinceNow, sinceDate: time)
    }
}