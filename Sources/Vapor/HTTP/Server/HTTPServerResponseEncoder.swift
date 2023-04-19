import NIOCore
import NIOHTTP1
import NIOConcurrencyHelpers

final class HTTPServerResponseEncoder: ChannelOutboundHandler, RemovableChannelHandler, Sendable {
    typealias OutboundIn = Response
    typealias OutboundOut = HTTPServerResponsePart
    
    /// Optional server header.
    private let serverHeader: String?
    private let dateCache: RFC1123DateCache

    struct ResponseEndSentEvent: Sendable { }
    
    init(serverHeader: String?, dateCache: RFC1123DateCache) {
        self.serverHeader = serverHeader
        self.dateCache = dateCache
    }
    
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let response = self.unwrapOutboundIn(data)
        // add a RFC1123 timestamp to the Date header to make this
        // a valid request
        response.headers.add(name: "date", value: self.dateCache.currentTimestamp())
        
        if let server = self.serverHeader {
            response.headers.add(name: "server", value: server)
        }
        
        // begin serializing
        context.write(wrapOutboundOut(.head(.init(
            version: response.version,
            status: response.status,
            headers: response.headers
        ))), promise: nil)

        
        if response.status == .noContent || response.forHeadRequest {
            // don't send bodies for 204 (no content) responses
            // or HEAD requests
            context.fireUserInboundEventTriggered(ResponseEndSentEvent())
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: promise)
        } else {
            switch response.body.storage {
            case .none:
                context.fireUserInboundEventTriggered(ResponseEndSentEvent())
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
            case .buffer(let buffer):
                self.writeAndflush(buffer: buffer, context: context, promise: promise)
            case .string(let string):
                let buffer = context.channel.allocator.buffer(string: string)
                self.writeAndflush(buffer: buffer, context: context, promise: promise)
            case .staticString(let string):
                let buffer = context.channel.allocator.buffer(staticString: string)
                self.writeAndflush(buffer: buffer, context: context, promise: promise)
            case .data(let data):
                let buffer = context.channel.allocator.buffer(bytes: data)
                self.writeAndflush(buffer: buffer, context: context, promise: promise)
            case .dispatchData(let data):
                let buffer = context.channel.allocator.buffer(dispatchData: data)
                self.writeAndflush(buffer: buffer, context: context, promise: promise)
            case .stream(let stream):
                let channelStream = ChannelResponseBodyStream(
                    context: context,
                    handler: self,
                    promise: promise,
                    count: stream.count == -1 ? nil : stream.count
                )
                stream.callback(channelStream)
            }
        }
    }
    
    /// Writes a `ByteBuffer` to the context.
    private func writeAndflush(buffer: ByteBuffer, context: ChannelHandlerContext, promise: EventLoopPromise<Void>?) {
        if buffer.readableBytes > 0 {
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        context.fireUserInboundEventTriggered(ResponseEndSentEvent())
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
    }
}

private final class ChannelResponseBodyStream: BodyStreamWriter {
    let contextBox: NIOLoopBound<ChannelHandlerContext>
    let handler: HTTPServerResponseEncoder
    let promise: EventLoopPromise<Void>?
    let count: Int?
    let currentCount: NIOLockedValueBox<Int>
    let isComplete: NIOLockedValueBox<Bool>

    var eventLoop: EventLoop {
        return self.contextBox.value.eventLoop
    }

    enum Error: Swift.Error, Sendable {
        case tooManyBytes
        case notEnoughBytes
    }

    init(
        context: ChannelHandlerContext,
        handler: HTTPServerResponseEncoder,
        promise: EventLoopPromise<Void>?,
        count: Int?
    ) {
        self.contextBox = .init(context, eventLoop: context.eventLoop)
        self.handler = handler
        self.promise = promise
        self.count = count
        self.currentCount = .init(0)
        self.isComplete = .init(false)
    }
    
    func write(_ result: BodyStreamResult, promise: EventLoopPromise<Void>?) {
        switch result {
        case .buffer(let buffer):
            self.contextBox.value.writeAndFlush(self.handler.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: promise)
            self.currentCount.withLockedValue {
                $0 += buffer.readableBytes
                if let count = self.count, $0 > count {
                    self.promise?.fail(Error.tooManyBytes)
                    promise?.fail(Error.notEnoughBytes)
                }
            }
        case .end:
            self.isComplete.withLockedValue { $0 = true }
            self.currentCount.withLockedValue {
                if let count = self.count, $0 != count {
                    self.promise?.fail(Error.notEnoughBytes)
                    promise?.fail(Error.notEnoughBytes)
                }
            }
            self.contextBox.value.fireUserInboundEventTriggered(HTTPServerResponseEncoder.ResponseEndSentEvent())
            self.contextBox.value.writeAndFlush(self.handler.wrapOutboundOut(.end(nil)), promise: promise)
            self.promise?.succeed(())
        case .error(let error):
            self.isComplete.withLockedValue { $0 = true }
            self.contextBox.value.fireUserInboundEventTriggered(HTTPServerResponseEncoder.ResponseEndSentEvent())
            self.contextBox.value.writeAndFlush(self.handler.wrapOutboundOut(.end(nil)), promise: promise)
            self.promise?.fail(error)
        }
    }

    deinit {
        assert(self.isComplete.withLockedValue { $0 }, "Response body stream writer deinitialized before .end or .error was sent.")
    }
}
