import FamilyDomain
import Foundation
import Testing

@testable import NestClient

/// Locks the pure Nest SDM wire layer (P15-C3): temperature conversion + setpoint rounding, the SDM
/// devices-response trait parsing (against a real-shape fixture), the `:executeCommand` body encoding,
/// the OAuth URL/PKCE/token builders, and the stateful mock. The token-refresh / 401-retry behavior is
/// locked in `NestSessionTests`.
struct NestOAuthAndParsingTests {

    // MARK: °C ↔ °F + setpoint rounding

    @Test func celsiusFahrenheitConversion() {
        #expect(NestTemp.cToF(22.0) == 71.6)          // ambient fixture
        #expect(NestTemp.cToF(23.0) == 73.4)
        #expect(NestTemp.cToF(0.0) == 32.0)
        #expect(abs(NestTemp.fToC(70) - 21.1111) < 0.001)
        #expect(abs(NestTemp.fToC(32) - 0.0) < 0.0001)
    }

    @Test func setpointRoundingIsRoundTripStable() {
        // A °F setpoint → Celsius → back to °F must land on the same integer.
        for f in 45...95 {
            #expect(NestTemp.cToFRounded(NestTemp.fToC(Double(f))) == f)
        }
        #expect(NestTemp.cToFRounded(20.0) == 68)     // SDM setpoint sample
        #expect(NestTemp.cToFRounded(22.0) == 72)
        #expect(NestLimits.clampF(120) == 95)
        #expect(NestLimits.clampF(10) == 45)
    }

    // MARK: SDM devices-response trait parsing

    /// A real-shape `devices.list` response: one THERMOSTAT (with the full trait set + a
    /// `parentRelations` room) and one non-thermostat device that must be filtered out.
    private let devicesJSON = """
    {
      "devices": [
        {
          "name": "enterprises/proj-123/devices/AVPHw1",
          "type": "sdm.devices.types.THERMOSTAT",
          "assignee": "enterprises/proj-123/structures/s1/rooms/r1",
          "traits": {
            "sdm.devices.traits.Info": { "customName": "" },
            "sdm.devices.traits.Humidity": { "ambientHumidityPercent": 35.0 },
            "sdm.devices.traits.Connectivity": { "status": "ONLINE" },
            "sdm.devices.traits.Temperature": { "ambientTemperatureCelsius": 23.0 },
            "sdm.devices.traits.ThermostatHvac": { "status": "HEATING" },
            "sdm.devices.traits.Settings": { "temperatureScale": "FAHRENHEIT" },
            "sdm.devices.traits.ThermostatMode": {
              "availableModes": ["HEAT", "COOL", "HEATCOOL", "OFF"],
              "mode": "HEAT"
            },
            "sdm.devices.traits.ThermostatTemperatureSetpoint": {
              "heatCelsius": 20.0,
              "coolCelsius": 22.0
            }
          },
          "parentRelations": [
            { "parent": "enterprises/proj-123/structures/s1/rooms/r1", "displayName": "Hallway" }
          ]
        },
        {
          "name": "enterprises/proj-123/devices/CAM9",
          "type": "sdm.devices.types.CAMERA",
          "traits": { "sdm.devices.traits.Info": { "customName": "Front Door" } },
          "parentRelations": [ { "parent": "x", "displayName": "Entry" } ]
        }
      ]
    }
    """

    @Test func parsesOnlyThermostatWithAllTraits() throws {
        let thermostats = try NestDevice.parseThermostats(Data(devicesJSON.utf8))
        #expect(thermostats.count == 1)                    // camera filtered out
        let t = try #require(thermostats.first)
        #expect(t.id == "enterprises/proj-123/devices/AVPHw1")
        #expect(t.deviceId == "AVPHw1")
        #expect(t.roomName == "Hallway")                   // from parentRelations.displayName
        #expect(t.mode == .heat)
        #expect(t.availableModes == [.heat, .cool, .heatCool, .off])
        #expect(t.humidityInt == 35)
        #expect(t.hvacStatus == "HEATING")
        #expect(t.ambientCelsius == 23.0)
        #expect(t.ambientF == 73.4)                        // °C→°F
        #expect(t.heatSetpointF == 68)                     // 20.0°C
        #expect(t.coolSetpointF == 72)                     // 22.0°C
        #expect(t.primarySetpointF == 68)                  // heat mode → heat setpoint
    }

    @Test func emptyDevicesArrayParsesToNothing() throws {
        #expect(try NestDevice.parseThermostats(Data("{\"devices\":[]}".utf8)).isEmpty)
    }

    // MARK: :executeCommand body encoding

    @Test func setHeatCommandBody() {
        let body = NestCommand.setpointBody(.heat(72))
        #expect(body["command"] as? String == "sdm.devices.commands.ThermostatTemperatureSetpoint.SetHeat")
        let params = try! #require(body["params"] as? [String: Double])
        #expect(abs((params["heatCelsius"] ?? 0) - NestTemp.fToC(72)) < 0.0001)
        #expect(params["coolCelsius"] == nil)
    }

    @Test func setCoolCommandBody() {
        let body = NestCommand.setpointBody(.cool(75))
        #expect(body["command"] as? String == "sdm.devices.commands.ThermostatTemperatureSetpoint.SetCool")
        let params = try! #require(body["params"] as? [String: Double])
        #expect(abs((params["coolCelsius"] ?? 0) - NestTemp.fToC(75)) < 0.0001)
    }

    @Test func setRangeCommandBody() {
        let body = NestCommand.setpointBody(.range(heat: 68, cool: 74))
        #expect(body["command"] as? String == "sdm.devices.commands.ThermostatTemperatureSetpoint.SetRange")
        let params = try! #require(body["params"] as? [String: Double])
        #expect(abs((params["heatCelsius"] ?? 0) - NestTemp.fToC(68)) < 0.0001)
        #expect(abs((params["coolCelsius"] ?? 0) - NestTemp.fToC(74)) < 0.0001)
    }

    @Test func setModeCommandBody() {
        #expect(NestCommand.modeBody(.off)["command"] as? String == "sdm.devices.commands.ThermostatMode.SetMode")
        #expect((NestCommand.modeBody(.off)["params"] as? [String: String])?["mode"] == "OFF")
        #expect((NestCommand.modeBody(.heatCool)["params"] as? [String: String])?["mode"] == "HEATCOOL")
    }

    /// The command body serializes to valid JSON (what the transport POSTs).
    @Test func commandBodySerializesToJSON() throws {
        let data = try JSONSerialization.data(withJSONObject: NestCommand.setpointBody(.heat(70)))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["command"] as? String == "sdm.devices.commands.ThermostatTemperatureSetpoint.SetHeat")
    }

    // MARK: OAuth URL + PKCE + token parsing

    @Test func authorizationURLUsesPartnerConnectionsWithProjectAndPKCE() throws {
        let config = NestConfig(projectId: "proj-123", oauthClientId: "cid.apps.googleusercontent.com", oauthClientSecret: "sec")
        let url = try #require(NestOAuth.authorizationURL(config: config, codeChallenge: "CHAL"))
        #expect(url.host == "nestservices.google.com")
        #expect(url.path == "/partnerconnections/proj-123/auth")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func val(_ n: String) -> String? { items.first { $0.name == n }?.value }
        #expect(val("client_id") == "cid.apps.googleusercontent.com")
        #expect(val("scope") == "https://www.googleapis.com/auth/sdm.service")
        #expect(val("access_type") == "offline")
        #expect(val("prompt") == "consent")
        #expect(val("response_type") == "code")
        #expect(val("redirect_uri") == "com.copoche.menere.nest:/oauth2redirect")
        #expect(val("code_challenge") == "CHAL")
        #expect(val("code_challenge_method") == "S256")
    }

    @Test func authorizationURLNilWithoutCredentials() {
        #expect(NestOAuth.authorizationURL(config: NestConfig(projectId: "", oauthClientId: ""), codeChallenge: "x") == nil)
    }

    @Test func extractsAuthorizationCodeFromRedirect() throws {
        let url = URL(string: "com.copoche.menere.nest:/oauth2redirect?code=4/ABC-xyz&scope=sdm")!
        #expect(NestOAuth.authorizationCode(from: url) == "4/ABC-xyz")
        let denied = URL(string: "com.copoche.menere.nest:/oauth2redirect?error=access_denied")!
        #expect(NestOAuth.authorizationCode(from: denied) == nil)
    }

    @Test func refreshRequestCarriesGrantAndSecret() throws {
        let config = NestConfig(projectId: "p", oauthClientId: "cid", oauthClientSecret: "sec", refreshToken: "R")
        let req = NestOAuth.refreshRequest(config: config, refreshToken: "R")
        #expect(req.url == NestOAuth.tokenEndpoint)
        #expect(req.httpMethod == "POST")
        let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("refresh_token=R"))
        #expect(body.contains("client_id=cid"))
        #expect(body.contains("client_secret=sec"))
    }

    @Test func tokenExchangeRequestOmitsSecretWhenAbsent() throws {
        let config = NestConfig(projectId: "p", oauthClientId: "cid")   // no secret (PKCE public client)
        let req = NestOAuth.tokenExchangeRequest(config: config, code: "CODE", codeVerifier: "VER")
        let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code=CODE"))
        #expect(body.contains("code_verifier=VER"))
        #expect(!body.contains("client_secret"))
    }

    @Test func parsesTokenResponse() throws {
        let json = #"{"access_token":"AT","refresh_token":"RT","expires_in":3599,"token_type":"Bearer"}"#
        let tokens = try NestOAuth.parseTokens(Data(json.utf8))
        #expect(tokens.accessToken == "AT")
        #expect(tokens.refreshToken == "RT")
        #expect(tokens.expiresIn == 3599)

        // A refresh response omits refresh_token.
        let refreshOnly = try NestOAuth.parseTokens(Data(#"{"access_token":"AT2","expires_in":3600}"#.utf8))
        #expect(refreshOnly.refreshToken == nil)
    }

    @Test func parseTokensThrowsOnMissingAccessToken() {
        #expect(throws: NestError.self) { try NestOAuth.parseTokens(Data(#"{"error":"invalid_grant"}"#.utf8)) }
    }

    @Test func pkceChallengeIsBase64URLSHA256() {
        // Known RFC 7636 test vector.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let pkce = NestPKCE(verifier: verifier)
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(!pkce.challenge.contains("="))   // no padding
        #expect(!pkce.challenge.contains("+"))
        #expect(!pkce.challenge.contains("/"))
    }
}
