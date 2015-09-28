//
//  Request.swift
//  Siesta
//
//  Created by Paul on 2015/7/20.
//  Copyright © 2015 Bust Out Solutions. All rights reserved.
//

/**
  HTTP request methods.
  
  See the various `Resource.request(...)` methods.
*/
public enum RequestMethod: String
    {
    /// GET
    case GET
    
    /// POST. Just POST. Doc comment is the same as the enum.
    case POST
    
    /// So you’re really reading the docs for all these, huh?
    case PUT
    
    /// OK then, I’ll reward your diligence. Or punish it, depending on your level of refinement.
    ///
    /// What’s the difference between a poorly maintained Greyhound terminal and a lobster with breast implants?
    case PATCH
    
    /// One’s a crusty bus station, and the other’s a busty crustacean.
    /// Thank you for reading the documentation!
    case DELETE
    }

/**
  Registers hooks to receive notifications about the status of a network request, and some request control.
  
  Note that these hooks are for only a _single request_, whereas `ResourceObserver`s receive notifications about
  _all_ resource load requests, no matter who initiated them. Note also that these hooks are available for _all_
  requests, whereas `ResourceObserver`s only receive notifications about changes triggered by `load()`, `loadIfNeeded()`,
  and `localDataOverride(_:)`.
  
  There is no race condition between a callback being added and a response arriving. If you add a callback after the
  response has already arrived, the callback is still called as usual.
  
  Request guarantees that it will call a given callback _at most_ one time.
  
  Callbacks are always called on the main queue.
*/
public class Request<ContentType>: AnyObject
    {
    private init() { }
    
    /// Call the closure once when the request finishes for any reason.
    func completion(callback: Response<ContentType> -> Void) -> Self
        { fatalError("abstract method") }
    
    /// Call the closure once if the request succeeds.
    func success(callback: Entity<ContentType> -> Void) -> Self
        { fatalError("abstract method") }
    
    /// Call the closure once if the request succeeds and the data changed.
    func newData(callback: Entity<ContentType> -> Void) -> Self
        { fatalError("abstract method") }
    
    /// Call the closure once if the request succeeds with a 304.
    func notModified(callback: Void -> Void) -> Self
        { fatalError("abstract method") }

    /// Call the closure once if the request fails for any reason.
    func failure(callback: Error -> Void) -> Self
        { fatalError("abstract method") }
    
    /**
      True if the request has received and handled a server response, encountered a pre-request client-side side error,
      or been cancelled.
    */
    var completed: Bool
        { fatalError("abstract method") }
    
    /**
      Cancel the request if it is still in progress. Has no effect if a response has already been received.
        
      If this method is called while the request is in progress, it immediately triggers the `failure`/`completion`
      callbacks with an `NSError` with the domain `NSURLErrorDomain` and the code `NSURLErrorCancelled`.
      
      Note that `cancel()` is not guaranteed to stop the request from reaching the server. In fact, it is not guaranteed
      to have any effect at all on the underlying request, subject to the whims of the `NetworkingProvider`. Therefore,
      after calling this method on a mutating request (POST, PUT, etc.), you should consider the service-side state of
      the resource to be unknown. Is it safest to immediately call either `Resource.load()` or `Resource.wipe()`.
      
      This method _does_ guarantee, however, that after it is called, even if a network response does arrive it will be
      ignored and not trigger any callbacks.
    */
    func cancel()
        { fatalError("abstract method") }
    }

/**
  The outcome of a network request: either success (with an entity representing the resource’s current state), or
  failure (with an error).
*/
public enum Response<T>: CustomStringConvertible
    {
    /// The request succeeded, and returned the given entity.
    case Success(Entity<T>)
    
    /// The request failed because of the given error.
    case Failure(Error)
    
    /// True if this is a cancellation response
    public var isCancellation: Bool
        {
        if case .Failure(let error) = self
            { return error.isCancellation }
        else
            { return false }
        }
    
    /// :nodoc:
    public var description: String
        {
        switch self
            {
            case .Success(let value): return debugStr(value)
            case .Failure(let value): return debugStr(value)
            }
        }
    }

private struct ResponseInfo<T>
    {
    var response: Response<T>
    var isNew: Bool
    }

internal final class NetworkRequest<T>: Request<T>, CustomDebugStringConvertible
    {
    private typealias ResponseCallback = ResponseInfo<T> -> Void
    
    // Basic metadata
    private let resource: Resource<T>
    private let requestDescription: String
    
    // Networking
    private var nsreq: NSURLRequest?             // present only before start()
    internal var networking: RequestNetworking?  // present only after start()
    
    // Result
    private var responseInfo: ResponseInfo<T>?
    internal var underlyingNetworkRequestCompleted = false      // so tests can wait for it to finish
    override internal var completed: Bool { return responseInfo != nil }
    
    // Callbacks
    private var responseCallbacks: [ResponseCallback] = []

    init(resource: Resource<T>, nsreq: NSURLRequest)
        {
        self.resource = resource
        self.nsreq = nsreq
        self.requestDescription = debugStr([nsreq.HTTPMethod, nsreq.URL])
        }
    
    func start() -> Self
        {
        guard networking == nil else
            { fatalError("NetworkRequest.start() called twice") }
        
        guard let nsreq = nsreq else
            {
            debugLog(.Network, [requestDescription, "will not start because it was already cancelled"])
            underlyingNetworkRequestCompleted = true
            return self
            }
        
        debugLog(.Network, [requestDescription])
        
        networking = resource.service.networkingProvider.startRequest(nsreq)
            {
            res, data, err in
            dispatch_async(dispatch_get_main_queue())
                { self.responseReceived(nsres: res, body: data, nserror: err) }
            }
        
        return self
        }
    
    override func cancel()
        {
        guard !completed else
            {
            debugLog(.Network, ["cancel() called but request already completed:", requestDescription])
            return
            }
        
        debugLog(.Network, ["Cancelled", requestDescription])
        
        networking?.cancel()
        
        // Prevent start() from have having any effect if it hasn't been called yet
        nsreq = nil

        broadcastResponse(
            ResponseInfo(
                response: .Failure(Error(
                    userMessage: "Request cancelled",
                    error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: nil))),
                isNew: true))
        }
    
    // MARK: Callbacks

    override func completion(callback: Response<T> -> Void) -> Self
        {
        addResponseCallback
            { callback($0.response) }
        return self
        }
    
    override func success(callback: Entity<T> -> Void) -> Self
        {
        addResponseCallback
            {
            if case .Success(let entity) = $0.response
                { callback(entity) }
            }
        return self
        }
    
    override func newData(callback: Entity<T> -> Void) -> Self
        {
        addResponseCallback
            {
            if case .Success(let entity) = $0.response where $0.isNew
                { callback(entity) }
            }
        return self
        }
    
    override func notModified(callback: Void -> Void) -> Self
        {
        addResponseCallback
            {
            if case .Success = $0.response where !$0.isNew
                { callback() }
            }
        return self
        }
    
    override func failure(callback: Error -> Void) -> Self
        {
        addResponseCallback
            {
            if case .Failure(let error) = $0.response
                { callback(error) }
            }
        return self
        }
    
    private func addResponseCallback(callback: ResponseCallback)
        {
        if let responseInfo = responseInfo
            {
            // Request already completed. Callback can run immediately, but queue it on the main thread so that the
            // caller can finish their business first.
            
            dispatch_async(dispatch_get_main_queue())
                { callback(responseInfo) }
            }
        else
            {
            // Request not yet completed.
            
            responseCallbacks.append(callback)
            }
        }
    
    // MARK: Response handling
    
    // Entry point for response handling. Triggered by RequestNetworking completion callback.
    private func responseReceived(nsres nsres: NSHTTPURLResponse?, body: NSData?, nserror: NSError?)
        {
        underlyingNetworkRequestCompleted = true
        
        debugLog(.Network, [nsres?.statusCode ?? nserror, "←", requestDescription])
        debugLog(.NetworkDetails, ["Raw response headers:", nsres?.allHeaderFields])
        debugLog(.NetworkDetails, ["Raw response body:", body?.length ?? 0, "bytes"])
        
        let (newResponse, existingResponse) = interpretResponse(nsres, body, nserror)
        
        if let existingResponse = existingResponse
            {
            broadcastResponse(
                ResponseInfo(response: existingResponse, isNew: false))
            }
        
        if let newResponse = newResponse
            {
            transformResponse(newResponse, then: broadcastResponse)
            }
        }
    
    private func interpretResponse(nsres: NSHTTPURLResponse?, _ body: NSData?, _ nserror: NSError?)
        -> (newData: Response<Any>?, existingData: Response<T>?)
        {
        if nsres?.statusCode >= 400 || nserror != nil
            {
            return (.Failure(Error(nsres, body, nserror)), nil)
            }
        else if nsres?.statusCode == 304
            {
            if let entity = resource.latestData
                {
                return (nil, .Success(entity))
                }
            else
                {
                return (
                    .Failure(Error(
                        userMessage: "No data",
                        debugMessage: "Received HTTP 304, but resource has no existing data")),
                    nil)
                }
            }
        else if let body = body
            {
            let entity = Entity<Any>(response: nsres, content: body)
            let response: Response<Any> = .Success(entity)
            return (response, nil)
            }
        else
            {
            return (.Failure(Error(userMessage: "Empty response")), nil)
            }
        }
    
    private func transformResponse(raw: Response<Any>, then afterTransformation: ResponseInfo<T> -> Void)
        {
        if shouldIgnoreResponse(raw)
            { return }
        
        let transformer = resource.config.responseTransformers
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0))
            {
            let processed = transformer.process(raw)
            let processedAndTyped: Response<T>
            switch processed
                {
                case let .Success(entity):
                    if let entityCast: Entity<T> = entity.typecastContent()
                        { processedAndTyped = .Success(entityCast) }
                    else
                        {
                        processedAndTyped = .Failure(Error(
                            userMessage: "Unable to parse response",
                            debugMessage: "Expected \(T.self) but got \(entity.content.dynamicType)",
                            entity: entity.typecastContent()))
                        }
                
                case let .Failure(error):
                    processedAndTyped = .Failure(error)
                }
            
            dispatch_async(dispatch_get_main_queue())
                {
                afterTransformation(ResponseInfo(response: processedAndTyped, isNew: true))
                }
            }
        }

    private func broadcastResponse(newInfo: ResponseInfo<T>)
        {
        if shouldIgnoreResponse(newInfo.response)
            { return }
        
        debugLog(.NetworkDetails, ["Response after transformer pipeline:", newInfo.isNew ? " (new data)" : " (data unchanged)", newInfo.response.dump("   ")])
        
        responseInfo = newInfo   // Remember outcome in case more handlers are added after request is already completed

        for callback in responseCallbacks
            { callback(newInfo) }
        responseCallbacks = []   // Fly, little handlers, be free!
        }
    
    private func shouldIgnoreResponse<U>(newResponse: Response<U>) -> Bool
        {
        guard let responseInfo = responseInfo else
            { return false }

        // We already received a response; don't broadcast another one.
        
        if !responseInfo.response.isCancellation
            {
            debugLog(.Network,
                [
                "WARNING: Received response for request that was already completed:", requestDescription,
                "This may indicate a bug in the NetworkingProvider you are using, or in Siesta.",
                "Please file a bug report: https://github.com/bustoutsolutions/siesta/issues/new",
                "\n    Previously received:", responseInfo.response,
                "\n    New response:", newResponse
                ])
            }
        else if !newResponse.isCancellation
            {
            // Sometimes the network layer sends a cancellation error. That’s not of interest if we already knew
            // we were cancelled. If we received any other response after cancellation, log that we ignored it.
            
            debugLog(.NetworkDetails,
                [
                "Received response, but request was already cancelled:", requestDescription,
                "\n    New response:", newResponse
                ])
            }
        
        return true
        }
    
    // MARK: Debug

    var debugDescription: String
        {
        return "Siesta.Request:"
            + String(ObjectIdentifier(self).uintValue, radix: 16)
            + "("
            + requestDescription
            + ")"
        }
    }


/// For requests that failed before they even made it to the network layer
internal final class FailedRequest<T>: Request<T>
    {
    private let error: Error
    
    init(_ error: Error)
        { self.error = error }
    
    override func completion(callback: Response<T> -> Void) -> Self
        {
        dispatch_async(dispatch_get_main_queue(), { callback(.Failure(self.error)) })
        return self
        }
    
    override func failure(callback: Error -> Void) -> Self
        {
        dispatch_async(dispatch_get_main_queue(), { callback(self.error) })
        return self
        }
    
    // Everything else is a noop
    
    override func success(callback: Entity<T> -> Void) -> Self { return self }
    override func newData(callback: Entity<T> -> Void) -> Self { return self }
    override func notModified(callback: Void -> Void) -> Self { return self }
    
    override func cancel() { }

    override var completed: Bool { return true }
    }
