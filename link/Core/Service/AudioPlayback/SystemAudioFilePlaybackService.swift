//
//  SystemAudioFilePlaybackService.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import AVFoundation
import Foundation

@MainActor
final class SystemAudioFilePlaybackService: NSObject, AudioFilePlaybackService {
    private var audioPlayer: AVAudioPlayer?
    private var currentPlaybackID: UUID?
    var playbackEventHandler: ((AudioFilePlaybackEvent) -> Void)?

    func play(url: URL, playbackID: UUID) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let error = AudioFilePlaybackError.fileNotFound
            emit(.failed(playbackID: playbackID, message: error.userFacingMessage))
            throw error
        }

        do {
            try configureAudioSession()
        } catch let error as AudioFilePlaybackError {
            emit(.failed(playbackID: playbackID, message: error.userFacingMessage))
            throw error
        } catch {
            let wrappedError = AudioFilePlaybackError.playbackUnavailable(error.localizedDescription)
            emit(.failed(playbackID: playbackID, message: wrappedError.userFacingMessage))
            throw wrappedError
        }

        stop()

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            currentPlaybackID = playbackID
            audioPlayer = player
            player.prepareToPlay()

            guard player.play() else {
                throw AudioFilePlaybackError.playbackUnavailable("录音文件无法开始播放。")
            }

            emit(.started(playbackID: playbackID))
        } catch let error as AudioFilePlaybackError {
            currentPlaybackID = nil
            audioPlayer = nil
            finishAudioSessionIfNeeded()
            emit(.failed(playbackID: playbackID, message: error.userFacingMessage))
            throw error
        } catch {
            let wrappedError = AudioFilePlaybackError.playbackUnavailable(error.localizedDescription)
            currentPlaybackID = nil
            audioPlayer = nil
            finishAudioSessionIfNeeded()
            emit(.failed(playbackID: playbackID, message: wrappedError.userFacingMessage))
            throw wrappedError
        }
    }

    func stop() {
        guard let player = audioPlayer,
              let playbackID = currentPlaybackID else {
            audioPlayer = nil
            currentPlaybackID = nil
            return
        }

        audioPlayer = nil
        currentPlaybackID = nil
        player.stop()
        emit(.cancelled(playbackID: playbackID))
        finishAudioSessionIfNeeded()
    }

    private func configureAudioSession() throws {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw AudioFilePlaybackError.audioSessionUnavailable(error.localizedDescription)
        }
    }

    private func finishAudioSessionIfNeeded() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func emit(_ event: AudioFilePlaybackEvent) {
        playbackEventHandler?(event)
    }
}

@MainActor
extension SystemAudioFilePlaybackService: @preconcurrency AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        _ = player
        guard let playbackID = currentPlaybackID else {
            finishAudioSessionIfNeeded()
            return
        }

        audioPlayer = nil
        currentPlaybackID = nil
        emit(flag ? .finished(playbackID: playbackID) : .cancelled(playbackID: playbackID))
        finishAudioSessionIfNeeded()
    }

    func audioPlayerDecodeErrorDidOccur(
        _ player: AVAudioPlayer,
        error: Error?
    ) {
        _ = player

        guard let playbackID = currentPlaybackID else {
            finishAudioSessionIfNeeded()
            return
        }

        let detail = error?.localizedDescription ?? ""
        let wrappedError = AudioFilePlaybackError.playbackUnavailable(detail)
        audioPlayer = nil
        currentPlaybackID = nil
        emit(.failed(playbackID: playbackID, message: wrappedError.userFacingMessage))
        finishAudioSessionIfNeeded()
    }
}
