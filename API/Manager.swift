//
//  Manager.swift
//  API
//
//  Created by 王义川 on 15/7/13.
//  Copyright © 2015年 肇庆市创威发展有限公司. All rights reserved.
//

import Foundation


public class Manager<T, U>: ManagerType {
    public typealias ParametersType = T
    public typealias ResultType = U
    public typealias RequestType = Request<ParametersType, ResultType>
    
    private var dispatchRequests: [RequestType] = []
    
    public let URL: NSURL
    public let method: Method
    
    public init(URL: NSURL, method: Method = .POST) {
        self.URL = URL
        self.method = method
    }
    
    public convenience init(URLString: String) throws {
        guard let URL = NSURL(string: URLString) else {
            throw Error.IllegalURLString(URLString)
        }
        self.init(URL: URL)
    }
    
    deinit {
        cancelAll()
    }

    public func request(parameters: ParametersType, serializer: RequestType.Serializer, deserializer: RequestType.Deserializer) -> RequestType {
        return Request(method: method, URL: URL, parameters: parameters, serializer: serializer, deserializer: deserializer)
            .beforeCalling { [unowned self] request in
                self.dispatchRequests.append(request)
            }
            .completion { [unowned self] request in
                if let index = self.dispatchRequests.indexOf({ $0 === request }) {
                    self.dispatchRequests.removeAtIndex(index)
                }
            }
            .response { (request: RequestType) in
                if let serverTime = request.response?.serverTime {
                    ServerTime.sharedInstance = ServerTime(date: serverTime)
                }
            }
    }
    
    public func cancelAll() {
        for request in dispatchRequests {
            request.cancel()
        }
        dispatchRequests.removeAll()
    }
}

public protocol ManagerType {
    typealias ParametersType
    typealias ResultType
    
    func request(parameters: ParametersType, serializer: Request<ParametersType, ResultType>.Serializer, deserializer: Request<ParametersType, ResultType>.Deserializer) -> Request<ParametersType, ResultType>
}

extension ManagerType where ParametersType == Void {
    public func request(deserializer deserializer: Request<Void, ResultType>.Deserializer) -> Request<Void, ResultType> {
        return request((), serializer: Self.serialize, deserializer: deserializer)
    }
    
    public static func serialize() -> NSData? {
        return nil
    }
}

extension ManagerType where ResultType == Void {
    public func request(parameters: ParametersType, serializer: Request<ParametersType, Void>.Serializer) -> Request<ParametersType, Void> {
        return request(parameters, serializer: serializer, deserializer: Self.deserialize)
    }
    
    public static func deserialize(_: ParametersType, _: NSURLRequest, _: NSHTTPURLResponse, _: NSData?) {
    }
}

extension ManagerType where ParametersType == Void, ResultType == Void {
    public func request() -> Request<Void, Void> {
        return request((), serializer: Self.serialize, deserializer: Self.deserialize)
    }
}