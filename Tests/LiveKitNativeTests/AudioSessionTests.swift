import XCTest
@testable import LiveKitNative

final class AudioSessionTests: XCTestCase {
    func testVoiceChatAudioSessionConfigurationDefaultsForLiveKitCalls() {
        let configuration = AudioSessionConfiguration.voiceChat

        XCTAssertEqual(configuration.sampleRate, 48_000)
        XCTAssertEqual(configuration.preferredIOBufferDuration, 0.02)
        XCTAssertTrue(configuration.allowsBluetooth)
        XCTAssertFalse(configuration.allowsBluetoothA2DP)
        XCTAssertTrue(configuration.allowsAirPlay)
        XCTAssertTrue(configuration.defaultToSpeaker)
        XCTAssertFalse(configuration.mixWithOthers)
        XCTAssertFalse(configuration.duckOthers)
    }

    func testRoomOptionsCarryAudioSessionConfiguration() {
        let configuration = AudioSessionConfiguration(
            sampleRate: 44_100,
            preferredIOBufferDuration: 0.01,
            allowsBluetooth: false,
            allowsBluetoothA2DP: true,
            allowsAirPlay: false,
            defaultToSpeaker: false,
            mixWithOthers: true,
            duckOthers: true
        )
        let options = RoomOptions(
            automaticallyConfigureAudioSession: true,
            audioSessionConfiguration: configuration
        )

        XCTAssertTrue(options.automaticallyConfigureAudioSession)
        XCTAssertEqual(options.audioSessionConfiguration, configuration)
    }

    func testPlatformAudioSessionControllerIsSafeToCallInUnitTests() throws {
        let controller = AudioSessionController()

        try controller.configureForVoiceChat(.voiceChat)
        try controller.activate()
        try controller.deactivate()
    }
}
