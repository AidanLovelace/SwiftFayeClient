//
//  FayeClient.swift
//
//  Created by Aidan Lovelace on 5/29/20.
//  Copyright © 2020 Aidan Lovelace. All rights reserved.
//

import Foundation
import Starscream
import Promises

class FayeClient {
    private var socketConnected: Bool = false
    private var socket: WebSocket!
    
    private var clientId: String!
    
    private var requestId: Int = 1
    
    var delegate: FayeClientDelegate
    
    init(withDelegate delegate: FayeClientDelegate) {
        self.delegate = delegate
        
        var request = URLRequest(url: self.delegate.websocketURL)
        request.timeoutInterval = 5
        self.socket = WebSocket(request: request)
        self.socket.delegate = self
    }
    
    func connect() {
        Promise<Void> {
            self.socket.connect()
            
            try await(self.handshakeRequest())
        }
    }
    
    func handshakeRequest() -> Promise<Void?> {
        // Prepare JSON data
        let handshakeRequest = FayeHandshakeRequest(id: "\(self.requestId)")
        self.requestId += 1 // Increment request id (not sure why this id is a thing at all)
        let jsonData = try! JSONEncoder().encode(handshakeRequest)
        
        return Promise { (fulfill, reject) in
            self.socket.write(data: jsonData) {
                fulfill(nil)
            }
        }
    }
    
    func subscribe(channel: String, extendedData ext: [ String : String ]) -> Promise<Bool> {
        // Prepare JSON data
        let subscriptionRequest = FayeSubscriptionRequest(id: "\(requestId)", clientId: self.clientId!, subscription: channel, ext: ext)
        requestId += 1 // Increment request id (not sure why this id is a thing at all)

        var request = URLRequest(url: self.delegate.handshakeURL)
        request.httpMethod = "POST"
        request.httpBody = try? JSONEncoder().encode(subscriptionRequest)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        return promiseRequest(request: request)
                .then({ data in
                    return try JSONDecoder().decode(FayeSubscriptionResponse.self, from: data)
                }).then({ (response) -> Bool in
                    if !response.successful {
                        throw NSError(domain: "", code: 100, userInfo: [
                            NSLocalizedDescriptionKey: "Subscription failed"
                        ])
                    }
                    return response.successful
                })
    }
    
    func basicconnect() {
    }
}

extension FayeClient: WebSocketDelegate {
    func didReceive(event: WebSocketEvent, client: WebSocket) {
        switch event {
        case .connected(_):
            socketConnected = true
        case .disconnected(let reason, let code):
            socketConnected = false
            delegate.clientDidDisconnect(reason: reason, code: Int(code))
        case .text(let string):
            guard let messages = try? JSONDecoder().decode([PushMessage].self, from: string.data(using: .utf8)!) else {
                return
            }
            for message in messages {
                if message.channel.starts(with: "/meta") {
                    switch message.channel {
                    case "/meta/handshake":
                        self.clientId = message.clientID
                        continue
                    case "/meta/connect":
                        socket.disconnect()
                        connect()
                        continue
                    default:
                        continue
                    }
                }
                delegate.clientDidReceiveMessage(json: string, fayeData: message)
            }
        case .binary(_):
            break
        case .ping(_):
            break
        case .pong(_):
            break
        case .viabilityChanged(_):
            break
        case .reconnectSuggested(_):
            break
        case .cancelled:
            socketConnected = false
        case .error(let error):
            socketConnected = false
            delegate.clientDidError(error)
        }
    }
}

fileprivate struct FayeHandshakeRequest : Codable {
    var id: String
    var channel: String = "/meta/handshake"
    var version: String = "1.0"
    var supportedConnectionTypes: [String] = ["websocket"]
}

fileprivate struct FayeSubscriptionRequest : Codable {
    var id: String
    var channel: String = "/meta/subscribe"
    var clientId: String
    var subscription: String
    var ext: [ String : String ]
}

fileprivate struct FayeSubscriptionResponse : Codable {
    var id: String
    var channel: String
    var clientId: String
    var subscription: String
    var successful: Bool
}

fileprivate struct FayeConnectionRequest : Codable {
    var id: String
    var channel: String = "/meta/connect"
    var clientId: String
    var connectionType: String = "websocket"
}

class PushMessage : Decodable {
    let clientID, channel, id: String
    let successful: Bool?
    let advice: FayeAdvice?
    let version: String?
    let supportedConnectionTypes: [String]?
    let subscription: String?

    enum CodingKeys: String, CodingKey {
        case clientID = "clientId"
        case channel, id, successful, advice, version, supportedConnectionTypes, subscription
    }
}

struct FayeAdvice: Codable {
    let timeout: Int
    let reconnect: String
    let interval: Int
}

protocol FayeClientDelegate {    
    var handshakeURL: URL { get }
    
    var websocketURL: URL { get }
    
    func clientDidError(_ error: Error?)
    
    func clientDidConnect(_ headers: [String : String])
    
    func clientDidDisconnect(reason: String, code: Int)
    
    func clientDidReceiveMessage(json: String, fayeData: PushMessage)
}
