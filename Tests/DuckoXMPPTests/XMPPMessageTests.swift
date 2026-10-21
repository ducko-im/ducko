import Testing
@testable import DuckoXMPP

enum XMPPMessageTests {
    struct MessageType {
        @Test
        func `Missing type returns normal`() {
            let element = XMLElement(name: "message", attributes: ["from": "contact@example.com"])
            let message = XMPPMessage(element: element)
            #expect(message.messageType == .normal)
        }

        @Test
        func `Unrecognized type returns normal`() {
            let element = XMLElement(name: "message", attributes: ["type": "foo"])
            let message = XMPPMessage(element: element)
            #expect(message.messageType == .normal)
        }

        @Test
        func `Chat type returns chat`() {
            let message = XMPPMessage(type: .chat)
            #expect(message.messageType == .chat)
        }

        @Test
        func `Groupchat type returns groupchat`() {
            let message = XMPPMessage(type: .groupchat)
            #expect(message.messageType == .groupchat)
        }

        @Test
        func `Error type returns error`() {
            let message = XMPPMessage(type: .error)
            #expect(message.messageType == .error)
        }

        @Test
        func `Headline type returns headline`() {
            let message = XMPPMessage(type: .headline)
            #expect(message.messageType == .headline)
        }

        @Test
        func `Normal type returns normal`() {
            let message = XMPPMessage(type: .normal)
            #expect(message.messageType == .normal)
        }
    }

    struct Thread {
        @Test
        func `Thread getter returns child text`() {
            var element = XMLElement(name: "message", attributes: ["type": "chat"])
            var threadChild = XMLElement(name: "thread")
            threadChild.addText("abc-123")
            element.addChild(threadChild)
            let message = XMPPMessage(element: element)
            #expect(message.thread == "abc-123")
        }

        @Test
        func `Thread setter creates child element`() {
            var message = XMPPMessage(type: .chat)
            message.thread = "xyz-456"
            #expect(message.thread == "xyz-456")
        }

        @Test
        func `Thread is nil when not present`() {
            let message = XMPPMessage(type: .chat)
            #expect(message.thread == nil)
        }

        @Test
        func `Thread setter clears child element`() {
            var message = XMPPMessage(type: .chat)
            message.thread = "to-be-removed"
            message.thread = nil
            #expect(message.thread == nil)
        }
    }

    struct ThreadParent {
        @Test
        func `Returns parent attribute from thread element`() {
            var element = XMLElement(name: "message", attributes: ["type": "chat"])
            var threadChild = XMLElement(name: "thread", attributes: ["parent": "parent-thread-id"])
            threadChild.addText("child-thread-id")
            element.addChild(threadChild)
            let message = XMPPMessage(element: element)
            #expect(message.threadParent == "parent-thread-id")
        }

        @Test
        func `Returns nil when thread has no parent attribute`() {
            var element = XMLElement(name: "message", attributes: ["type": "chat"])
            var threadChild = XMLElement(name: "thread")
            threadChild.addText("abc-123")
            element.addChild(threadChild)
            let message = XMPPMessage(element: element)
            #expect(message.threadParent == nil)
        }

        @Test
        func `Returns nil when no thread element`() {
            let message = XMPPMessage(type: .chat)
            #expect(message.threadParent == nil)
        }
    }

    struct LocalizedContent {
        @Test
        func `Returns all body elements with lang`() {
            var element = XMLElement(name: "message", attributes: ["type": "chat"])
            var bodyEn = XMLElement(name: "body", attributes: ["xml:lang": "en"])
            bodyEn.addText("Hello")
            var bodyDe = XMLElement(name: "body", attributes: ["xml:lang": "de"])
            bodyDe.addText("Hallo")
            element.addChild(bodyEn)
            element.addChild(bodyDe)
            let message = XMPPMessage(element: element)
            #expect(message.localizedBodies.count == 2)
            #expect(message.localizedBodies[0] == XMPPMessage.LocalizedText(lang: "en", text: "Hello"))
            #expect(message.localizedBodies[1] == XMPPMessage.LocalizedText(lang: "de", text: "Hallo"))
        }

        @Test
        func `Body without lang returns nil lang`() {
            var element = XMLElement(name: "message", attributes: ["type": "chat"])
            var body = XMLElement(name: "body")
            body.addText("Hi")
            element.addChild(body)
            let message = XMPPMessage(element: element)
            #expect(message.localizedBodies.count == 1)
            #expect(message.localizedBodies[0].lang == nil)
            #expect(message.localizedBodies[0].text == "Hi")
        }

        @Test
        func `body convenience returns first match`() {
            var element = XMLElement(name: "message", attributes: ["type": "chat"])
            var bodyDefault = XMLElement(name: "body")
            bodyDefault.addText("Default")
            var bodyFr = XMLElement(name: "body", attributes: ["xml:lang": "fr"])
            bodyFr.addText("Bonjour")
            element.addChild(bodyDefault)
            element.addChild(bodyFr)
            let message = XMPPMessage(element: element)
            #expect(message.body == "Default")
        }

        @Test
        func `Returns all subject elements with lang`() {
            var element = XMLElement(name: "message", attributes: ["type": "groupchat"])
            var subjectEn = XMLElement(name: "subject", attributes: ["xml:lang": "en"])
            subjectEn.addText("Welcome")
            var subjectEs = XMLElement(name: "subject", attributes: ["xml:lang": "es"])
            subjectEs.addText("Bienvenido")
            element.addChild(subjectEn)
            element.addChild(subjectEs)
            let message = XMPPMessage(element: element)
            #expect(message.localizedSubjects.count == 2)
            #expect(message.localizedSubjects[0] == XMPPMessage.LocalizedText(lang: "en", text: "Welcome"))
            #expect(message.localizedSubjects[1] == XMPPMessage.LocalizedText(lang: "es", text: "Bienvenido"))
        }

        @Test
        func `Empty localizedBodies when no body elements`() {
            let message = XMPPMessage(type: .chat)
            #expect(message.localizedBodies.isEmpty)
        }

        @Test
        func `Empty localizedSubjects when no subject elements`() {
            let message = XMPPMessage(type: .chat)
            #expect(message.localizedSubjects.isEmpty)
        }
    }

    struct OOB {
        @Test
        func `Returns OOB data with URL and description`() {
            var element = XMLElement(name: "message", attributes: ["type": "chat"])
            var oobX = XMLElement(name: "x", namespace: XMPPNamespaces.oob)
            var urlChild = XMLElement(name: "url")
            urlChild.addText("https://example.com/photo.jpg")
            var descChild = XMLElement(name: "desc")
            descChild.addText("A photo")
            oobX.addChild(urlChild)
            oobX.addChild(descChild)
            element.addChild(oobX)
            let message = XMPPMessage(element: element)
            #expect(message.oobData.count == 1)
            #expect(message.oobData[0].url == "https://example.com/photo.jpg")
            #expect(message.oobData[0].desc == "A photo")
        }

        @Test
        func `Returns empty when no OOB elements`() {
            let message = XMPPMessage(type: .chat)
            #expect(message.oobData.isEmpty)
        }

        @Test
        func `Returns multiple OOB entries`() {
            var element = XMLElement(name: "message", attributes: ["type": "chat"])
            for urlString in ["https://example.com/a.jpg", "https://example.com/b.pdf"] {
                var oobX = XMLElement(name: "x", namespace: XMPPNamespaces.oob)
                var urlChild = XMLElement(name: "url")
                urlChild.addText(urlString)
                oobX.addChild(urlChild)
                element.addChild(oobX)
            }
            let message = XMPPMessage(element: element)
            #expect(message.oobData.count == 2)
            #expect(message.oobData[0].url == "https://example.com/a.jpg")
            #expect(message.oobData[1].url == "https://example.com/b.pdf")
        }

        @Test
        func `Skips OOB with empty URL`() {
            var element = XMLElement(name: "message", attributes: ["type": "chat"])
            var oobX = XMLElement(name: "x", namespace: XMPPNamespaces.oob)
            let urlChild = XMLElement(name: "url")
            oobX.addChild(urlChild)
            element.addChild(oobX)
            let message = XMPPMessage(element: element)
            #expect(message.oobData.isEmpty)
        }

        @Test
        func `Returns OOB data without description`() {
            var element = XMLElement(name: "message", attributes: ["type": "chat"])
            var oobX = XMLElement(name: "x", namespace: XMPPNamespaces.oob)
            var urlChild = XMLElement(name: "url")
            urlChild.addText("https://example.com/file.zip")
            oobX.addChild(urlChild)
            element.addChild(oobX)
            let message = XMPPMessage(element: element)
            #expect(message.oobData.count == 1)
            #expect(message.oobData[0].url == "https://example.com/file.zip")
            #expect(message.oobData[0].desc == nil)
        }
    }

    struct ClassifiedEvent {
        @Test(arguments: [
            ("<message type='groupchat' from='room@conference.example.com/nick'><body>Hi</body></message>", true),
            ("<message type='chat' from='contact@example.com/res'><retract id='1' xmlns='urn:xmpp:message-retract:1'/></message>", true),
            ("<message from='room@conference.example.com'><x xmlns='http://jabber.org/protocol/muc#user'><invite from='contact@example.com'/></x></message>", true),
            ("<message from='contact@example.com/res'><x xmlns='jabber:x:conference' jid='room@conference.example.com'/></message>", true),
            ("<message type='chat' from='room@conference.example.com/nick'><body>Hi</body><x xmlns='http://jabber.org/protocol/muc#user'/></message>", true),
            ("<message type='chat' from='contact@example.com/res'><encrypted xmlns='urn:xmpp:omemo:2'><header sid='1'/></encrypted></message>", true),
            ("<message from='room@conference.example.com'><x xmlns='http://jabber.org/protocol/muc#user'><decline from='contact@example.com'/></x></message>", false),
            ("<message type='chat' from='contact@example.com/res'><body>Hi</body></message>", false)
        ])
        func `Messages a module reports as their own event are classified`(xml: String, isClassified: Bool) throws {
            #expect(try XMPPMessage(element: stanza(xml)).hasClassifiedEvent == isClassified)
        }
    }
}
