//
//  Errors.swift
//  API
//
//  Created by 王义川 on 15/7/13.
//  Copyright © 2015年 肇庆市创威发展有限公司. All rights reserved.
//

import Foundation


public enum Error: ErrorType {
    case IllegalURLString(String)
    case SerializeFailure(String)
    case DeserializeFailure(String)
    case RequestFailure
    case RequestCancelled
}