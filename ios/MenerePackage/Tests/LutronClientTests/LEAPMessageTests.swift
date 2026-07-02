import FamilyDomain
import Foundation
import Testing

@testable import LutronClient

/// Round-trips the LEAP wire layer (P15-C1). The command JSON shapes are asserted against what
/// pylutron-caseta (`smartbridge.set_value` / `_send_zone_create_request`) and lutron-leap-js
/// (`Messages.ts`) put on the wire; the status/device fixtures mirror those repos' response shapes
/// (`OneZoneStatus`, `MultipleDeviceDefinition`).
struct LEAPMessageTests {

    private func json(_ request: LEAPRequest) throws -> [String: Any] {
        // Strip the trailing \r\n framing, parse back to a dictionary for structural assertions.
        var data = try request.framed()
        #expect(data.suffix(2) == Data([0x0d, 0x0a]))   // newline-delimited framing
        data.removeLast(2)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func goToLevelEncodesCommandProcessorCreateRequest() throws {
        let obj = try json(.goToLevel(zoneId: "5", level: 45, tag: "set5"))
        #expect(obj["CommuniqueType"] as? String == "CreateRequest")
        let header = try #require(obj["Header"] as? [String: Any])
        #expect(header["Url"] as? String == "/zone/5/commandprocessor")
        #expect(header["ClientTag"] as? String == "set5")
        let command = try #require((obj["Body"] as? [String: Any])?["Command"] as? [String: Any])
        #expect(command["CommandType"] as? String == "GoToLevel")
        let parameter = try #require(command["Parameter"] as? [[String: Any]])
        #expect(parameter.first?["Type"] as? String == "Level")
        #expect(parameter.first?["Value"] as? Int == 45)
    }

    @Test func goToLevelClampsOutOfRange() throws {
        let over = try json(.goToLevel(zoneId: "5", level: 250))
        let overValue = ((over["Body"] as? [String: Any])?["Command"] as? [String: Any])?["Parameter"] as? [[String: Any]]
        #expect(overValue?.first?["Value"] as? Int == 100)

        let under = try json(.goToLevel(zoneId: "5", level: -10))
        let underValue = ((under["Body"] as? [String: Any])?["Command"] as? [String: Any])?["Parameter"] as? [[String: Any]]
        #expect(underValue?.first?["Value"] as? Int == 0)
    }

    @Test func raiseLowerStopAreBareCommands() throws {
        for (builder, expected) in [
            (LEAPRequest.raise(zoneId: "8"), "Raise"),
            (LEAPRequest.lower(zoneId: "8"), "Lower"),
            (LEAPRequest.stop(zoneId: "8"), "Stop"),
        ] {
            let obj = try json(builder)
            #expect(obj["CommuniqueType"] as? String == "CreateRequest")
            let command = try #require((obj["Body"] as? [String: Any])?["Command"] as? [String: Any])
            #expect(command["CommandType"] as? String == expected)
            #expect(command["Parameter"] == nil)   // no Parameter for bare commands
        }
    }

    @Test func readRequestHasNoBody() throws {
        let obj = try json(.read("/device", tag: "devices"))
        #expect(obj["CommuniqueType"] as? String == "ReadRequest")
        #expect((obj["Header"] as? [String: Any])?["Url"] as? String == "/device")
        #expect(obj["Body"] == nil)
    }

    // MARK: Response decode (fixtures shaped like the reference repos' test data)

    @Test func decodesOneZoneStatusLevel() throws {
        let fixture = """
        {"CommuniqueType":"ReadResponse","Header":{"StatusCode":"200 OK","Url":"/zone/5/status"},"Body":{"ZoneStatus":{"href":"/zone/5/status","Level":63,"Zone":{"href":"/zone/5"}}}}
        """
        let frames = LEAPResponse.frames(from: Data(fixture.utf8))
        let frame = try #require(frames.first)
        #expect(frame.isSuccessful)
        let status = try #require(frame.decodeBody(LEAPOneZoneStatusBody.self)?.zoneStatus)
        #expect(status.level == 63)
        #expect(status.zoneId == "5")
    }

    @Test func decodesDevicesFilteringShades() throws {
        let fixture = """
        {"CommuniqueType":"ReadResponse","Header":{"StatusCode":"200 OK","Url":"/device"},"Body":{"Devices":[\
        {"href":"/device/1","Name":"Smart Bridge","DeviceType":"SmartBridge"},\
        {"href":"/device/5","Name":"Oliver Shade","DeviceType":"SerenaHoneycombShade","LocalZones":[{"href":"/zone/5"}],"AssociatedArea":{"href":"/area/3"}},\
        {"href":"/device/8","Name":"Living Shade","DeviceType":"SerenaRollerShade","LocalZones":[{"href":"/zone/8"}],"AssociatedArea":{"href":"/area/2"}}\
        ]}}
        """
        let frame = try #require(LEAPResponse.frames(from: Data(fixture.utf8)).first)
        let devices = try #require(frame.decodeBody(LEAPDevicesBody.self)?.devices)
        #expect(devices.count == 3)
        let shades = devices.filter(\.isShade)
        #expect(shades.count == 2)
        #expect(shades.first?.zoneId == "5")
        #expect(shades.first?.areaId == "3")
    }

    @Test func decodesAreas() throws {
        let fixture = """
        {"CommuniqueType":"ReadResponse","Header":{"StatusCode":"200 OK"},"Body":{"Areas":[{"href":"/area/3","Name":"Oliver's room"},{"href":"/area/2","Name":"Living room"}]}}
        """
        let frame = try #require(LEAPResponse.frames(from: Data(fixture.utf8)).first)
        let areas = try #require(frame.decodeBody(LEAPAreasBody.self)?.areas)
        #expect(areas.count == 2)
        #expect(areas.first { $0.areaId == "3" }?.name == "Oliver's room")
    }

    @Test func multipleFramesSplitOnNewlines() throws {
        // Two newline-delimited frames (CRLF-framed, as the bridge sends).
        let line1 = #"{"CommuniqueType":"ReadResponse","Header":{"StatusCode":"200 OK"}}"#
        let line2 = #"{"CommuniqueType":"SubscribeResponse","Header":{"StatusCode":"200 OK"}}"#
        let buffer = Data((line1 + "\r\n" + line2 + "\r\n").utf8)
        let frames = LEAPResponse.frames(from: buffer)
        let types = frames.map(\.communiqueType)
        #expect(types == [.readResponse, .subscribeResponse])
    }

    @Test func exceptionResponseIsNotSuccessful() throws {
        let fixture = """
        {"CommuniqueType":"ExceptionResponse","Header":{"StatusCode":"401 Unauthorized"}}
        """
        let frame = try #require(LEAPResponse.frames(from: Data(fixture.utf8)).first)
        #expect(frame.isSuccessful == false)
    }
}
