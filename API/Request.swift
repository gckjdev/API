//
//  Request.swift
//  API
//
//  Created by 王义川 on 15/7/14.
//  Copyright © 2015年 肇庆市创威发展有限公司. All rights reserved.
//

import Foundation
import Alamofire


public enum Method: String {
    case OPTIONS = "OPTIONS"
    case GET = "GET"
    case HEAD = "HEAD"
    case POST = "POST"
    case PUT = "PUT"
    case PATCH = "PATCH"
    case DELETE = "DELETE"
    case TRACE = "TRACE"
    case CONNECT = "CONNECT"
}

public enum Priority : Int {
    case VeryLow
    case Low
    case Normal
    case High
    case VeryHigh
}

public class Request<ParametersType, ResultType> {
    public typealias Serializer = (ParametersType) throws -> NSData?
    public typealias Deserializer = (ParametersType, NSURLRequest, NSHTTPURLResponse, NSData?) throws -> ResultType
    public typealias Processor = (NSMutableURLRequest) throws -> Void
    public typealias Interceptor = (Request<ParametersType, ResultType>) -> Void
    public typealias Validation = (ParametersType,  NSURLRequest, NSHTTPURLResponse, NSData?) throws -> Void
    public typealias RetryCondition = (ParametersType,  NSURLRequest?, NSHTTPURLResponse?, NSData?, ResultType?, ErrorType?, UInt) throws -> Bool
    public typealias Preprocess = () throws -> Void
    
    private typealias PriorityProcessor = (processor: Processor, priority: Priority)
    
    public let method: Method
    public let URL: NSURL
    public let parameters: ParametersType
    public let serializer: Serializer
    public let deserializer: Deserializer
    public var preprocess: Preprocess?
    
    private var requestTask: Alamofire.Request?
    public private(set) var called = false
    public private(set) var cancelled = false
    
    private var processors : [PriorityProcessor] = []
    private var beforeCallingInterceptors: [Interceptor] = []
    private var afterCallingInterceptors: [Interceptor] = []
    private var completionInterceptors: [Interceptor] = []
    private var validations: [Validation] = []
    private let queue: NSOperationQueue = {
        let operationQueue = NSOperationQueue()
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.suspended = true
        operationQueue.qualityOfService = .Utility
        return operationQueue
    }()
    
    private var retryTimes:UInt = 0
    private var retryConditions: [RetryCondition] = []
    
    public private(set) var completed: Bool {
        get {
            return !self.queue.suspended
        }
        set {
            self.queue.suspended = !newValue
            
            if completed {
                let currentQueue = NSOperationQueue.defaultQueue()
                for interceptor in completionInterceptors {
                    self.queue.addOperationWithBlock { [weak self] in
                        currentQueue.addOperationWithBlock{ [weak self] in
                            if let this = self {
                                interceptor(this)
                            }
                        }
                    }

                }
                completionInterceptors.removeAll()
            }
        }
    }
    
    public private(set) var request: NSURLRequest?
    public private(set) var response: NSHTTPURLResponse?
    public private(set) var responseData: NSData?
    public private(set) var error: ErrorType?
    public private(set) var result: ResultType?
    
    init(method: Method, URL: NSURL, parameters: ParametersType, serializer: Serializer, deserializer: Deserializer) {
        self.method = method
        self.URL = URL
        self.parameters = parameters
        self.serializer = serializer
        self.deserializer = deserializer
    }

    deinit {
        queue.cancelAllOperations()
        cancel()
    }
    
    public func call() -> Self {
        if cancelled || called {
            return self
        }
        called = true
        
        beforeCalling()
        doCall()
        afterCalling()
        
        return self
    }
    
    public func cancel() {
        if cancelled || completed {
            return
        }
        cancelled = true
        
        if let task = requestTask {
            task.cancel()
        } else {
            error = Error.RequestCancelled
            self.completed = true
        }
    }
    
    private func doCall() {
        guard let preprocess = preprocess else {
            perform()
            return
        }
        
        let currentQueue = NSOperationQueue.defaultQueue()
        NSOperationQueue().addOperationWithBlock { [weak self] in
            var err: ErrorType?
            do {
                try preprocess()
            } catch {
                err = error
            }
            currentQueue.addOperationWithBlock{ [weak self] in
                guard let this = self else { return }
                if let error = err {
                    this.error = error
                    this.retryOrComplete()
                } else {
                    this.perform()
                }
            }
        }
    }
    
    private func perform() {
        do {
            requestTask = Alamofire.request(try generateURLRequest()).response{ [weak self] request, response, responseData, error in
                guard let this = self else {
                    return
                }
                
                this.requestTask = nil
                
                this.request = request
                this.response = response
                this.responseData = responseData
                this.error = error
                this.processRequestResult()
                
                this.retryOrComplete()
            }
        } catch {
            self.error = error
            retryOrComplete()
        }
    }
    
    private func retry() {
        ++retryTimes
        clearRequestResult()
        doCall()
    }
    
    private func retryOrComplete() {
        if retryConditions.isEmpty {
            self.completed = true
            return
        }
        
        let currentQueue = NSOperationQueue.defaultQueue()
        NSOperationQueue().addOperationWithBlock { [weak self] in
            guard let this = self else { return }
            var isRetryable = false
            var err: ErrorType?
            do {
                for condition in this.retryConditions {
                    if try condition(this.parameters, this.request, this.response, this.responseData, this.result, this.error, this.retryTimes) {
                        isRetryable = true
                        break
                    }
                }
            } catch {
                err = error
            }
            currentQueue.addOperationWithBlock { [weak self] in
                guard let this = self else { return }
                if let error = err {
                    this.error = error
                    this.completed = true
                } else if isRetryable {
                    this.retry()
                } else {
                    this.completed = true
                }
            }
        }
    }
    
    private func beforeCalling() {
        for interceptor in beforeCallingInterceptors {
            interceptor(self)
        }
        beforeCallingInterceptors.removeAll()
    }
    
    private func afterCalling() {
        for interceptor in afterCallingInterceptors {
            interceptor(self)
        }
        afterCallingInterceptors.removeAll()
    }
    
    private func process(mutableURLRequest: NSMutableURLRequest) throws {
        processors.sortInPlace { $0.priority.rawValue > $1.priority.rawValue }
        for item in processors {
            try item.processor(mutableURLRequest)
        }
    }
    
    private func generateURLRequest() throws -> NSURLRequest {
        let parametersData = try serializer(parameters)
        let mutableURLRequest = generateURLRequest(parametersData)
        try process(mutableURLRequest)
        return mutableURLRequest
    }
    
    private func generateURLRequest(parameters: NSData?) -> NSMutableURLRequest {
        let mutableURLRequest = NSMutableURLRequest(URL: URL)
        
        mutableURLRequest.HTTPMethod = method.rawValue
        mutableURLRequest.addValue("charset=\(CFStringConvertEncodingToIANACharSetName(CFStringConvertNSStringEncodingToEncoding(NSUTF8StringEncoding)))", forHTTPHeaderField: "Content-Type")
        mutableURLRequest.HTTPBody = parameters
        
        return mutableURLRequest
    }
    
    private func processRequestResult() {
        if error != nil {
            return
        }
        
        guard let request = self.request, response = self.response else {
            error = Error.RequestFailure
            return
        }
        
        do {
            for validation in validations {
                try validation(parameters, request, response, responseData)
            }
            
            result = try self.deserializer(parameters, request, response, responseData)
        } catch {
            self.error = error
        }
    }
    
    private func clearRequestResult() {
        request = nil
        response = nil
        responseData = nil
        error = nil
        result = nil
    }
}

extension Request {
    public func process(processor: Processor) -> Self {
        return process(priority: .Normal, processor: processor)
    }
    
    public func process(priority priority: Priority, processor: Processor) -> Self {
        if !called {
            processors.append((processor, priority))
        }
        return self
    }
}

extension Request {
    public func retry(condition: RetryCondition) -> Self {
        if !called {
            retryConditions.append(condition)
        }
        return self
    }
}

extension Request {
    public func beforeCalling(interceptor: Interceptor) -> Self {
        if !called {
            beforeCallingInterceptors.append(interceptor)
        }
        return self
    }
    
    public func afterCalling(interceptor: Interceptor) -> Self {
        if !called {
            afterCallingInterceptors.append(interceptor)
        }
        return self
    }
    
    func completion(interceptor: Interceptor) -> Self {
        completionInterceptors.append(interceptor)
        
        return self
    }
}

extension Request {
    public func validate(validation: Validation) -> Self {
        if !completed {
            validations.append(validation)
        }
        return self
    }
}

extension Request {
    public typealias CompletionHandler = (ParametersType,  NSURLRequest?, NSHTTPURLResponse?, NSData?, ResultType?, ErrorType?) -> Void
    public typealias SuccessHandler = (ParametersType,  NSURLRequest, NSHTTPURLResponse, NSData?, ResultType) -> Void
    public typealias FailureHandler = (ParametersType,  NSURLRequest?, NSHTTPURLResponse?, NSData?, ResultType?, ErrorType) -> Void
    
    public func response(queue queue: NSOperationQueue = NSOperationQueue.defaultQueue(), completionHandler: (Request<ParametersType, ResultType>) -> Void) -> Self {
        let currentQueue = NSOperationQueue.defaultQueue()
        self.queue.addOperationWithBlock { [weak self] in
            currentQueue.addOperationWithBlock{ [weak self] in
                if let this = self {
                    completionHandler(this)
                }
            }
        }
        return self
    }
    
    public func response(queue queue: NSOperationQueue = NSOperationQueue.defaultQueue(), completionHandler: CompletionHandler) -> Self {
        return response(queue: queue) { this in
            completionHandler(this.parameters, this.request, this.response, this.responseData, this.result, this.error)
        }
    }
    
    public func response(queue queue: NSOperationQueue = NSOperationQueue.defaultQueue(), completionHandler: (ParametersType, ResultType?, ErrorType?) -> Void) -> Self {
        return response(queue: queue) { this in
            completionHandler(this.parameters, this.result, this.error)
        }
    }
    
    public func response(queue queue: NSOperationQueue = NSOperationQueue.defaultQueue(), completionHandler: (ResultType?, ErrorType?) -> Void) -> Self {
        return response(queue: queue) { this in
            completionHandler(this.result, this.error)
        }
    }
    
    public func response(queue queue: NSOperationQueue = NSOperationQueue.defaultQueue(), successHandler: SuccessHandler, failureHandler: FailureHandler? = nil) -> Self {
        return response(queue: queue) { (this: Request<ParametersType, ResultType>) in
            if let err = this.error {
                failureHandler?(this.parameters, this.request, this.response, this.responseData, this.result, err)
            } else {
                successHandler(this.parameters, this.request!, this.response!, this.responseData, this.result!)
            }
        }
    }
    
    public func response(queue queue: NSOperationQueue = NSOperationQueue.defaultQueue(), successHandler: (ParametersType, ResultType) -> Void, failureHandler: ((ParametersType, ErrorType) -> Void)? = nil) -> Self {
        return response(queue: queue) { (this: Request<ParametersType, ResultType>) in
            if let err = this.error {
                failureHandler?(this.parameters, err)
            } else {
                successHandler(this.parameters, this.result!)
            }
        }
    }
    
    public func response(queue queue: NSOperationQueue = NSOperationQueue.defaultQueue(), successHandler: (ResultType) -> Void, failureHandler: ((ErrorType) -> Void)? = nil) -> Self {
        return response(queue: queue) { (this: Request<ParametersType, ResultType>) in
            if let err = this.error {
                failureHandler?(err)
            } else {
                successHandler(this.result!)
            }
        }
    }
}

extension NSOperationQueue {
    private static func defaultQueue() -> NSOperationQueue {
        return NSOperationQueue.currentQueue() ?? NSOperationQueue.mainQueue()
    }
}