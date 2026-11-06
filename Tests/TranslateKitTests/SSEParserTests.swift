import Testing
import Foundation
import TranslateKit

@Suite("SSE 解析")
struct SSEParserTests {
    @Test("一个完整帧派发一个事件")
    func singleFrame() {
        var parser = SSEParser()
        let events = parser.feed(Data("data: hello\n\n".utf8))
        #expect(events == [.data("hello")])
    }

    @Test("chunk 边界把一行切断也能还原")
    func truncatedMidLine() {
        var parser = SSEParser()
        var events: [SSEParser.Event] = []
        events += parser.feed(Data("data: {\"choices\":[{\"delta\":{\"cont".utf8))
        events += parser.feed(Data("ent\":\"你好\"}}]}\n".utf8))
        events += parser.feed(Data("\ndata: [DONE]\n\n".utf8))
        #expect(events.count == 2)
        #expect(events.first == .data("{\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}"))
        #expect(events.last == .done)
    }

    @Test("多行 data 用换行拼接，CRLF 正常剥离")
    func multiLineAndCRLF() {
        var parser = SSEParser()
        let events = parser.feed(Data("data: line1\r\ndata: line2\r\n\r\n".utf8))
        #expect(events == [.data("line1\nline2")])
    }

    @Test("畸形行被跳过且计数，不影响后续帧")
    func malformedLines() {
        var parser = SSEParser()
        let events = parser.feed(Data("garbage-without-colon\ndata: ok\n\n".utf8))
        #expect(events == [.data("ok")])
        #expect(parser.malformedLineCount == 1)
    }

    @Test("注释行（心跳）被忽略")
    func commentIgnored() {
        var parser = SSEParser()
        let events = parser.feed(Data(": keep-alive\n\ndata: payload\n\n".utf8))
        #expect(events == [.data("payload")])
    }

    @Test("结尾没有空行时 finish 冲刷残留")
    func finishFlushesTail() {
        var parser = SSEParser()
        let first = parser.feed(Data("data: tail-without-blank-line".utf8))
        #expect(first.isEmpty)
        #expect(parser.finish() == [.data("tail-without-blank-line")])
    }

    @Test("[DONE] 在无结尾空行时也能识别")
    func doneWithoutTrailingBlank() {
        var parser = SSEParser()
        _ = parser.feed(Data("data: [DONE]".utf8))
        #expect(parser.finish() == [.done])
    }

    @Test("逐字节喂入不丢字")
    func byteByByte() {
        let payload = "data: {\"choices\":[{\"delta\":{\"content\":\"逐字节\"}}]}\n\ndata: [DONE]\n\n"
        var parser = SSEParser()
        var events: [SSEParser.Event] = []
        for byte in Array(payload.utf8) {
            events += parser.feed(Data([byte]))
        }
        #expect(events.count == 2)
        #expect(events.last == .done)
    }
}
