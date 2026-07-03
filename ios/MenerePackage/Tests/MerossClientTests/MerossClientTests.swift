import FamilyDomain
import Foundation
import Testing

@testable import MerossClient

/// Locks the pure Meross LAN wire layer (P15-C5): the envelope + `MD5(messageId + key + timestamp)`
/// signing (against a known MD5 vector), the System.All + GarageDoor.State parsers (against faithfully-
/// shaped fixtures), the SET payload builder, and the stateful mock. NONE of this touches the network —
/// Michael's first live connect on the home LAN is the live test.
struct MerossClientTests {

    // MARK: envelope signing (MD5 vector)

    @Test func signIsMD5OfMessageIdKeyTimestamp() {
        // MD5("ab0") — the simplest vector: messageId "a", empty-ish concat with key "b", timestamp 0.
        #expect(MerossEnvelope.sign(messageId: "a", key: "b", timestamp: 0) == "449f2a4c69b93a105441494833db68e5")
        // A realistic vector with a device key.
        #expect(MerossEnvelope.sign(messageId: "msgid-1", key: "secret-key", timestamp: 1_700_000_000)
                == "eccebddedbcf123de94b69d8046bc493")
        // An empty key still signs (some Meross/Refoss devices accept a keyless envelope).
        #expect(MerossEnvelope.sign(messageId: "msgid-1", key: "", timestamp: 1_700_000_000)
                == "ae400b300ba75d9d1ac7b95d3bdf968a")
    }

    @Test func messageIdIs32HexChars() {
        let id = MerossEnvelope.generateMessageId()
        #expect(id.count == 32)
        #expect(id.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) })
        // Two draws differ (random).
        #expect(id != MerossEnvelope.generateMessageId())
    }

    @Test func envelopeCarriesSignedHeaderAndPayload() throws {
        let payload: [String: Any] = ["state": ["channel": 0]]
        let env = MerossEnvelope.envelope(
            method: MerossProtocol.methodSet, namespace: MerossProtocol.namespaceGarageState,
            payload: payload, key: "K", messageId: "MID", timestamp: 42
        )
        let header = try #require(env[MerossProtocol.keyHeader] as? [String: Any])
        #expect(header[MerossProtocol.keyMessageId] as? String == "MID")
        #expect(header[MerossProtocol.keyMethod] as? String == "SET")
        #expect(header[MerossProtocol.keyNamespace] as? String == "Appliance.GarageDoor.State")
        #expect(header[MerossProtocol.keyPayloadVersion] as? Int == 1)
        #expect(header[MerossProtocol.keyFrom] as? String == MerossProtocol.headerFrom)
        #expect(header[MerossProtocol.keyTriggerSrc] as? String == "Android")
        #expect(header[MerossProtocol.keyTimestamp] as? Int == 42)
        #expect(header[MerossProtocol.keySign] as? String == MerossEnvelope.sign(messageId: "MID", key: "K", timestamp: 42))
        #expect(env[MerossProtocol.keyPayload] as? [String: Any] != nil)
        // Serializes to valid JSON (what the transport POSTs).
        #expect(throws: Never.self) { try JSONSerialization.data(withJSONObject: env) }
    }

    // MARK: setGarage payload encode

    @Test func garageSetPayloadOpenAndClose() throws {
        let open = MerossEnvelope.garageSetPayload(channel: 0, open: true, uuid: "U")
        let openState = try #require(open[MerossProtocol.keyState] as? [String: Any])
        #expect(openState[MerossProtocol.keyChannel] as? Int == 0)
        #expect(openState[MerossProtocol.keyOpen] as? Int == 1)      // open → 1
        #expect(openState[MerossProtocol.keyUUID] as? String == "U")

        let close = MerossEnvelope.garageSetPayload(channel: 1, open: false, uuid: "U")
        let closeState = try #require(close[MerossProtocol.keyState] as? [String: Any])
        #expect(closeState[MerossProtocol.keyChannel] as? Int == 1)
        #expect(closeState[MerossProtocol.keyOpen] as? Int == 0)     // closed → 0
    }

    // MARK: System.All parse

    private let systemAllJSON = """
    {
      "header": { "namespace": "Appliance.System.All", "method": "GETACK" },
      "payload": {
        "all": {
          "system": {
            "hardware": { "type": "msg100", "uuid": "1808xxxxUUID", "macAddress": "34:29:8f:xx" },
            "firmware": { "version": "3.1.3", "innerIp": "192.168.1.42" }
          },
          "digest": {
            "garageDoor": [
              { "channel": 0, "open": 0, "lmTime": 1700000000 }
            ]
          }
        }
      }
    }
    """

    @Test func parsesDeviceInfoFromSystemAll() throws {
        let info = try MerossParse.deviceInfo(Data(systemAllJSON.utf8))
        #expect(info.uuid == "1808xxxxUUID")
        #expect(info.type == "msg100")
        #expect(info.channels.count == 1)
        #expect(info.channels.first?.channel == 0)
        #expect(info.channels.first?.isOpen == false)
    }

    @Test func deviceInfoThrowsWithoutUUID() {
        let json = #"{ "payload": { "all": { "system": { "hardware": { "type": "x" } } } } }"#
        #expect(throws: MerossError.self) { try MerossParse.deviceInfo(Data(json.utf8)) }
    }

    @Test func rejectsErrorNamespace() {
        // A wrong device key is rejected as an Error namespace — must throw, not silently parse.
        let json = #"{ "header": { "namespace": "Appliance.Control.Error" }, "payload": { "error": { "code": 5001 } } }"#
        #expect(throws: MerossError.self) { try MerossParse.deviceInfo(Data(json.utf8)) }
    }

    // MARK: GarageDoor.State parse (fixture)

    @Test func parsesGarageStateListForm() throws {
        // MSG200 multi-channel: state is a list.
        let json = """
        { "header": { "namespace": "Appliance.GarageDoor.State" },
          "payload": { "state": [
            { "channel": 0, "open": 1, "lmTime": 1 },
            { "channel": 1, "open": 0, "lmTime": 2 }
          ] } }
        """
        let doors = try MerossParse.garageState(Data(json.utf8))
        #expect(doors.count == 2)
        #expect(doors[0].channel == 0)
        #expect(doors[0].isOpen == true)
        #expect(doors[0].statusLine == "Open")
        #expect(doors[1].channel == 1)
        #expect(doors[1].isOpen == false)
        #expect(doors[1].statusLine == "Closed")
        // Channel 0 default name.
        #expect(doors[0].displayName == "Garage")
    }

    @Test func parsesGarageStateSingleDictForm() throws {
        // Some single-door units return state as one dict.
        let json = """
        { "payload": { "state": { "channel": 0, "open": 1 } } }
        """
        let doors = try MerossParse.garageState(Data(json.utf8))
        #expect(doors.count == 1)
        #expect(doors.first?.isOpen == true)
    }

    // MARK: transport wiring (envelope POSTed, response parsed) — no real network

    @Test func sessionSetsGaragePOSTsSignedEnvelopeToConfigPath() async throws {
        let captured = RequestBox()
        let http = MerossHTTPClient(perform: { req in
            await captured.set(req)
            let ok = #"{ "header": { "namespace": "Appliance.GarageDoor.StateAck" }, "payload": {} }"#
            return (Data(ok.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let session = MerossSession(http: http, now: { 42 }, messageId: { "MID" })
        let config = MerossConfig(deviceIP: "10.0.0.5", deviceKey: "K", uuid: "U")

        try await session.setGarage(config: config, channel: 0, open: true)

        let req = try #require(await captured.value)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "http://10.0.0.5/config")
        let body = try #require(req.httpBody)
        let root = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let header = try #require(root["header"] as? [String: Any])
        #expect(header["namespace"] as? String == "Appliance.GarageDoor.State")
        #expect(header["method"] as? String == "SET")
        #expect(header["sign"] as? String == MerossEnvelope.sign(messageId: "MID", key: "K", timestamp: 42))
        let state = try #require((root["payload"] as? [String: Any])?["state"] as? [String: Any])
        #expect(state["open"] as? Int == 1)
        #expect(state["uuid"] as? String == "U")
    }

    private actor RequestBox {
        private(set) var value: URLRequest?
        func set(_ r: URLRequest) { value = r }
    }

    // MARK: stateful mock

    @Test func mockStorePersistsGarageWrites() async {
        let store = MerossMockStore()
        await store.reset()

        // Seed: "Garage" closed.
        var doors = await store.doors()
        #expect(doors.count == 1)
        #expect(doors.first?.name == "Garage")
        #expect(doors.first?.isOpen == false)

        // Open channel 0 — persists.
        await store.setGarage(channel: 0, open: true)
        doors = await store.doors()
        #expect(doors.first?.isOpen == true)

        // Close again — persists.
        await store.setGarage(channel: 0, open: false)
        doors = await store.doors()
        #expect(doors.first?.isOpen == false)
    }

    @Test func mockConfigIsMockAndConnected() {
        #expect(MerossFixtures.mockConfig.isMock)
        #expect(MerossFixtures.mockConfig.isConnected)
        // A bare IP (no key) is still "connected" — the key may legitimately be empty.
        #expect(MerossConfig(deviceIP: "10.0.0.1").isConnected)
        #expect(!MerossConfig().isConnected)
    }
}
