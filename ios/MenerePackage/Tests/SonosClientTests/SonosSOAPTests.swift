import Foundation
import Testing

@testable import SonosClient

/// Locks the Sonos UPnP/SOAP wire layer (P15-C2): outgoing envelope encoding and the parsing of the
/// three response shapes the client depends on — `GetTransportInfo`, `GetPositionInfo` (escaped
/// DIDL-Lite `TrackMetaData`), `GetVolume`, and the escaped `ZoneGroupState` topology. The XML samples
/// mirror the real formats documented by SoCo (`core.py` / `groups.py`) and node-sonos.
struct SonosSOAPTests {

    // MARK: Envelope encode

    @Test func playEnvelopeMatchesUPnP() {
        let xml = SonosSOAP.envelope(
            action: "Play", service: .avTransport, args: [("InstanceID", "0"), ("Speed", "1")]
        )
        #expect(xml.contains("<u:Play xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"))
        #expect(xml.contains("<InstanceID>0</InstanceID>"))
        #expect(xml.contains("<Speed>1</Speed>"))
        #expect(xml.contains("s:Envelope"))
        #expect(SonosSOAP.soapAction(.avTransport, "Play") == "\"urn:schemas-upnp-org:service:AVTransport:1#Play\"")
    }

    @Test func setVolumeEnvelopeCarriesMasterChannel() {
        let xml = SonosSOAP.envelope(
            action: "SetVolume", service: .renderingControl,
            args: [("InstanceID", "0"), ("Channel", "Master"), ("DesiredVolume", "35")]
        )
        #expect(xml.contains("<u:SetVolume xmlns:u=\"urn:schemas-upnp-org:service:RenderingControl:1\">"))
        #expect(xml.contains("<Channel>Master</Channel>"))
        #expect(xml.contains("<DesiredVolume>35</DesiredVolume>"))
    }

    // MARK: Transport / volume parse

    @Test func transportStateFolding() {
        func state(_ code: String) -> SonosNowPlaying.PlaybackState {
            SonosSOAP.parseTransportState("<u:GetTransportInfoResponse><CurrentTransportState>\(code)</CurrentTransportState></u:GetTransportInfoResponse>")
        }
        #expect(state("PLAYING") == .playing)
        #expect(state("PAUSED_PLAYBACK") == .paused)
        #expect(state("STOPPED") == .stopped)
        #expect(state("TRANSITIONING") == .stopped)
    }

    @Test func volumeParse() {
        let xml = "<u:GetVolumeResponse><CurrentVolume>42</CurrentVolume></u:GetVolumeResponse>"
        #expect(SonosSOAP.parseVolume(xml) == 42)
    }

    // MARK: Now-playing DIDL-Lite

    /// A real GetPositionInfo response nests an *escaped* DIDL-Lite doc inside `TrackMetaData`.
    private let positionInfo = """
    <u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">\
    <Track>1</Track>\
    <TrackMetaData>&lt;DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" \
    xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"&gt;\
    &lt;item&gt;&lt;dc:title&gt;So What&lt;/dc:title&gt;\
    &lt;dc:creator&gt;Miles Davis&lt;/dc:creator&gt;\
    &lt;upnp:album&gt;Kind of Blue&lt;/upnp:album&gt;\
    &lt;upnp:albumArtURI&gt;/getaa?u=x&amp;amp;v=1&lt;/upnp:albumArtURI&gt;\
    &lt;/item&gt;&lt;/DIDL-Lite&gt;</TrackMetaData>\
    </u:GetPositionInfoResponse>
    """

    @Test func nowPlayingParsesTitleArtistAndAlbumArt() {
        let np = SonosSOAP.parseNowPlaying(positionInfoXML: positionInfo, transportState: .playing, speakerIP: "192.168.1.55")
        #expect(np.title == "So What")
        #expect(np.artist == "Miles Davis")
        #expect(np.state == .playing)
        #expect(np.albumArtURL?.absoluteString == "http://192.168.1.55:1400/getaa?u=x&v=1")
        #expect(np.line == "So What — Miles Davis")
    }

    @Test func nowPlayingIdleWhenNoMetadata() {
        let empty = "<u:GetPositionInfoResponse><TrackMetaData></TrackMetaData></u:GetPositionInfoResponse>"
        let np = SonosSOAP.parseNowPlaying(positionInfoXML: empty, transportState: .stopped, speakerIP: "10.0.0.9")
        #expect(np.title == nil)
        #expect(np.albumArtURL == nil)
        #expect(np.line == "Idle")
    }

    // MARK: ZoneGroupState topology

    /// Two groups: a bonded pair coordinated by the Living Room player (Kitchen grouped under it), and a
    /// solo Office. An invisible BOOST is present and must be dropped.
    private let zoneGroupState = """
    <u:GetZoneGroupStateResponse xmlns:u="urn:schemas-upnp-org:service:ZoneGroupTopology:1">\
    <ZoneGroupState>&lt;ZoneGroupState&gt;&lt;ZoneGroups&gt;\
    &lt;ZoneGroup Coordinator="RINCON_AAA01400" ID="RINCON_AAA01400:11"&gt;\
    &lt;ZoneGroupMember UUID="RINCON_AAA01400" Location="http://192.168.1.10:1400/xml/device_description.xml" ZoneName="Living Room"/&gt;\
    &lt;ZoneGroupMember UUID="RINCON_BBB01400" Location="http://192.168.1.11:1400/xml/device_description.xml" ZoneName="Kitchen"/&gt;\
    &lt;/ZoneGroup&gt;\
    &lt;ZoneGroup Coordinator="RINCON_CCC01400" ID="RINCON_CCC01400:22"&gt;\
    &lt;ZoneGroupMember UUID="RINCON_CCC01400" Location="http://192.168.1.12:1400/xml/device_description.xml" ZoneName="M&amp;amp;V Office"/&gt;\
    &lt;/ZoneGroup&gt;\
    &lt;ZoneGroup Coordinator="RINCON_ZZZ01400" ID="RINCON_ZZZ01400:99"&gt;\
    &lt;ZoneGroupMember UUID="RINCON_ZZZ01400" Location="http://192.168.1.99:1400/xml/device_description.xml" ZoneName="BOOST" Invisible="1"/&gt;\
    &lt;/ZoneGroup&gt;\
    &lt;/ZoneGroups&gt;&lt;/ZoneGroupState&gt;</ZoneGroupState>\
    </u:GetZoneGroupStateResponse>
    """

    @Test func zoneGroupStateParsesMembersGroupsAndCoordinators() {
        let speakers = SonosSOAP.parseZoneGroups(zoneGroupState)
        #expect(speakers.count == 3)   // BOOST dropped

        let living = speakers.first { $0.id == "RINCON_AAA01400" }
        #expect(living?.name == "Living Room")
        #expect(living?.ip == "192.168.1.10")
        #expect(living?.isCoordinator == true)
        #expect(living?.groupId == "RINCON_AAA01400:11")

        let kitchen = speakers.first { $0.id == "RINCON_BBB01400" }
        #expect(kitchen?.name == "Kitchen")
        #expect(kitchen?.isCoordinator == false)             // grouped under Living Room
        #expect(kitchen?.groupId == "RINCON_AAA01400:11")    // same group as its coordinator

        let office = speakers.first { $0.id == "RINCON_CCC01400" }
        #expect(office?.name == "M&V Office")                // double-unescaped (&amp;amp; → &amp; → &)
        #expect(office?.isCoordinator == true)
    }

    /// The bonded pair collapses to ONE group row (coordinator = Living Room, both as members); the solo
    /// Office is its own row. `roomOrder` floats the Office to the front.
    @Test func assembleGroupsCoalescesAndOrders() {
        let speakers = SonosSOAP.parseZoneGroups(zoneGroupState)
        let rows = SonosGroup.assemble(from: speakers, order: ["M&V Office"])
        #expect(rows.count == 2)
        #expect(rows[0].coordinator.name == "M&V Office")    // floated by roomOrder
        let pair = rows[1]
        #expect(pair.coordinator.name == "Living Room")
        #expect(pair.members.count == 2)

        let group = SonosGroup(coordinator: pair.coordinator, members: pair.members, nowPlaying: SonosNowPlaying(state: .playing), volume: 30)
        #expect(group.roomName == "Living Room + Kitchen")   // coordinator first
        #expect(group.id == "RINCON_AAA01400:11")
    }
}
