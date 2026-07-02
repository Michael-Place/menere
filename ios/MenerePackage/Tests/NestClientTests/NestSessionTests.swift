import FamilyDomain
import Foundation
import Testing

@testable import NestClient

/// Locks the token lifecycle (P15-C3): a cached access token is reused; a **401 forces exactly one
/// refresh + one retry**; and the stateful mock persists setpoint/mode writes across reads.
struct NestSessionTests {

    /// Records every outbound request so we can assert call ordering + counts.
    private actor CallLog {
        private(set) var urls: [String] = []
        private(set) var auths: [String?] = []
        func record(_ req: URLRequest) {
            urls.append(req.url?.absoluteString ?? "")
            auths.append(req.value(forHTTPHeaderField: "Authorization"))
        }
        var count: Int { urls.count }
        var refreshCount: Int { urls.filter { $0.contains("oauth2.googleapis.com/token") }.count }
    }

    private func ok(_ url: URL, _ json: String) -> (Data, HTTPURLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    private let config = NestConfig(projectId: "proj-1", oauthClientId: "cid", oauthClientSecret: "sec", refreshToken: "R")

    private let devicesFixture = """
    { "devices": [ {
        "name": "enterprises/proj-1/devices/D1",
        "type": "sdm.devices.types.THERMOSTAT",
        "traits": {
          "sdm.devices.traits.ThermostatMode": { "availableModes": ["HEAT","OFF"], "mode": "HEAT" },
          "sdm.devices.traits.Temperature": { "ambientTemperatureCelsius": 22.0 },
          "sdm.devices.traits.ThermostatTemperatureSetpoint": { "heatCelsius": 21.11 }
        },
        "parentRelations": [ { "parent": "x", "displayName": "Downstairs" } ]
    } ] }
    """

    /// A 401 on the devices call forces one refresh + one retry, then succeeds — total 3 calls, exactly
    /// one refresh.
    @Test func unauthorizedTriggersSingleRefreshAndRetry() async throws {
        let log = CallLog()
        let cache = NestTokenCache()
        // Pre-seed a still-valid token so the FIRST devices call uses it (isolating the 401→refresh path).
        await cache.store("STALE", expiry: Date().addingTimeInterval(3600), for: "R")

        let http = NestHTTPClient { req in
            await log.record(req)
            let url = req.url!
            if url.absoluteString.contains("oauth2.googleapis.com/token") {
                return self.ok(url, #"{"access_token":"FRESH","expires_in":3600}"#)
            }
            // Devices endpoint: reject the stale token once, accept the fresh one.
            if req.value(forHTTPHeaderField: "Authorization") == "Bearer STALE" {
                return (Data(), HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!)
            }
            return self.ok(url, self.devicesFixture)
        }

        let session = NestSession(config: config, http: http, cache: cache)
        let thermostats = try await session.thermostats()

        #expect(thermostats.count == 1)
        #expect(thermostats.first?.roomName == "Downstairs")
        #expect(await log.count == 3)          // devices(401) → refresh → devices(200)
        #expect(await log.refreshCount == 1)   // exactly one refresh
        #expect(await log.auths == ["Bearer STALE", nil, "Bearer FRESH"])
    }

    /// A fresh cached token is reused with NO refresh call.
    @Test func cachedTokenIsReusedWithoutRefresh() async throws {
        let log = CallLog()
        let cache = NestTokenCache()
        await cache.store("GOOD", expiry: Date().addingTimeInterval(3600), for: "R")

        let http = NestHTTPClient { req in
            await log.record(req)
            return self.ok(req.url!, self.devicesFixture)
        }
        let session = NestSession(config: config, http: http, cache: cache)
        _ = try await session.thermostats()

        #expect(await log.count == 1)          // just the devices call
        #expect(await log.refreshCount == 0)   // no refresh
    }

    /// With an empty cache the session refreshes once, then makes the devices call.
    @Test func emptyCacheRefreshesOnce() async throws {
        let log = CallLog()
        let cache = NestTokenCache()
        let http = NestHTTPClient { req in
            await log.record(req)
            if req.url!.absoluteString.contains("oauth2.googleapis.com/token") {
                return self.ok(req.url!, #"{"access_token":"T","expires_in":3600}"#)
            }
            return self.ok(req.url!, self.devicesFixture)
        }
        let session = NestSession(config: config, http: http, cache: cache)
        _ = try await session.thermostats()

        #expect(await log.refreshCount == 1)
        #expect(await log.count == 2)          // refresh → devices
    }

    // MARK: Stateful mock

    @Test func mockStorePersistsSetpointAndMode() async {
        let store = NestMockStore()
        await store.reset()
        let name = NestFixtures.downstairsName

        var t = await store.thermostats()
        #expect(t.first?.heatSetpointF == 70)   // seed
        #expect(t.first?.mode == .heat)

        await store.setTemperature(deviceName: name, setpoint: .heat(73))
        t = await store.thermostats()
        #expect(t.first?.heatSetpointF == 73)   // write persisted

        await store.setMode(deviceName: name, mode: .cool)
        t = await store.thermostats()
        #expect(t.first?.mode == .cool)         // mode persisted
        #expect(t.first?.heatSetpointF == 73)   // and the earlier setpoint still holds
    }
}
