// swift-tools-version: 6.0

import PackageDescription

/// A deliberately narrow package used to run the pure macOS regression suites
/// without launching either application target. The shipping products remain
/// defined by SpeakPaste.xcodeproj.
let package = Package(
    name: "SpeakPasteMacLogic",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "SpeakPasteKeychain",
            path: "SpeakPaste",
            exclude: [
                "AppModel.swift",
                "Assets.xcassets",
                "AudioRecorder.swift",
                "ContentView.swift",
                "DictationActivityAttributes.swift",
                "DictationEngine.swift",
                "DictationIntents.swift",
                "DictationLiveActivity.swift",
                "ElevenLabsClient.swift",
                "HistoryStore.swift",
                "HistoryView.swift",
                "HostAppSwitcher.swift",
                "Info.plist",
                "SettingsView.swift",
                "SharedDictation.swift",
                "SpeakPaste.entitlements",
                "SpeakPasteApp.swift",
                "TranscriptionModels.swift",
            ],
            sources: ["KeychainStore.swift"]
        ),
        .target(
            name: "SpeakPasteClient",
            path: "SpeakPaste",
            exclude: [
                "AppModel.swift",
                "Assets.xcassets",
                "AudioRecorder.swift",
                "ContentView.swift",
                "DictationActivityAttributes.swift",
                "DictationEngine.swift",
                "DictationIntents.swift",
                "DictationLiveActivity.swift",
                "HistoryStore.swift",
                "HistoryView.swift",
                "HostAppSwitcher.swift",
                "Info.plist",
                "KeychainStore.swift",
                "SettingsView.swift",
                "SharedDictation.swift",
                "SpeakPaste.entitlements",
                "SpeakPasteApp.swift",
            ],
            sources: [
                "ElevenLabsClient.swift",
                "TranscriptionModels.swift",
            ]
        ),
        .target(
            name: "SpeakPaste",
            path: "SpeakPasteMac",
            exclude: [
                "MacAppModel.swift",
                "MacAudioDevice.swift",
                "MacAudioRecorder.swift",
                "MacContentView.swift",
                "MacDeliveryTarget.swift",
                "MacGlobalHotKey.swift",
                "MacKeyboardLayout.swift",
                "MacPasteController.swift",
                "MacPermissions.swift",
                "MacReliabilityStore.swift",
                "MacSettingsView.swift",
                "MacSoundEffects.swift",
                "MacStatusHUD.swift",
                "Sounds",
                "SpeakPasteMacApp.swift",
            ],
            sources: [
                "MacDeliveryPolicyStore.swift",
                "MacDiagnostics.swift",
                "MacHistoryStore.swift",
                "MacActiveCaptureRecovery.swift",
                "MacPendingAudioStore.swift",
                "MacPendingTranscriptStore.swift",
                "MacPasteVerification.swift",
                "MacCommandGesture.swift",
                "MacHUDActivity.swift",
                "MacInputMode.swift",
                "MacSingleInstanceLease.swift",
                "MacTranscriptionWorkload.swift",
                "MacTranscriptPostProcessor.swift",
                "MacVocabularyStore.swift",
            ]
        ),
        .testTarget(
            name: "SpeakPasteMacTests",
            dependencies: ["SpeakPaste", "SpeakPasteKeychain"],
            path: "SpeakPasteMacTests"
        ),
        .testTarget(
            name: "SpeakPasteClientTests",
            dependencies: ["SpeakPasteClient"],
            path: "SpeakPasteTests",
            exclude: [
                "HistoryStoreTests.swift",
                "SharedDictationStoreTests.swift",
            ],
            sources: ["ElevenLabsClientTests.swift"]
        ),
    ]
)
