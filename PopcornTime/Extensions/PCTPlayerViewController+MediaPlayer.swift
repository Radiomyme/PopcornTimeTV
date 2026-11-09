

import Foundation
import MediaPlayer
import AlamofireImage

extension PCTPlayerViewController {
    
    /// Registers this player's handlers on the SHARED `MPRemoteCommandCenter`
    /// (Control Center, Siri, the Remote app) — once per session, at the first
    /// time tick. Every handler holds the player weakly (`.commandFailed` once
    /// it is gone), and `removeRemoteCommandCenterHandlers()` removes each
    /// target at close: the shared center must neither keep a closed player
    /// alive for the rest of the process (its views, its own libvlc instance)
    /// nor run its handlers on later remote commands (a stopped VLC
    /// restarting, hidden, on its old stream).
    func addRemoteCommandCenterHandlers() {
        removeRemoteCommandCenterTargets() // never registered twice
        let center = MPRemoteCommandCenter.shared()
        /// `handler` gets the player as an argument: it never captures it.
        func add(_ command: MPRemoteCommand, _ handler: @escaping (PCTPlayerViewController, MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            let target = command.addTarget { [weak self] event in
                guard let player = self else { return .commandFailed }
                return handler(player, event)
            }
            remoteCommandTargets.append((command: command, target: target))
        }
            
        add(center.pauseCommand) { player, _ in
            player.playandPause()
            return player.mediaplayer.state == .paused ? .success : .commandFailed
        }
        
        add(center.playCommand) { player, _ in
            player.playandPause()
            return player.mediaplayer.state == .playing ? .success : .commandFailed
        }
        
        // The seeks below are the user's moves of the playhead: VLC's
        // position counts from now on, also before the resume point
        // (`noteUserMovedPlayhead`, as the ±30 s buttons and the scrub do).
        if #available(iOS 9.1, tvOS 9.1, *) {
            add(center.changePlaybackPositionCommand) { player, event in
                player.mediaplayer.time = VLCTime(number: NSNumber(value: (event as! MPChangePlaybackPositionCommandEvent).positionTime * 1000))
                player.noteUserMovedPlayhead()
                return .success
            }
        }
        
        add(center.stopCommand) { player, _ in
            player.mediaplayer.stop()
            return .success
        }
        
        add(center.changePlaybackRateCommand) { player, event in
            player.mediaplayer.rate = (event as! MPChangePlaybackRateCommandEvent).playbackRate
            return .success
        }
        
        add(center.skipForwardCommand) { player, event in
            player.mediaplayer.jumpForward((event as! MPSkipIntervalCommandEvent).interval) // VLCKit 4: seconds as Double
            player.noteUserMovedPlayhead()
            return .success
        }

        add(center.skipBackwardCommand) { player, event in
            player.mediaplayer.jumpBackward((event as! MPSkipIntervalCommandEvent).interval)
            player.noteUserMovedPlayhead()
            return .success
        }
    }
    
    /// Close (`didFinishPlaying`): this player's targets leave the shared
    /// center, and its Now Playing info is cleared.
    func removeRemoteCommandCenterHandlers() {
        removeRemoteCommandCenterTargets()
        nowPlayingInfo = nil
        UIApplication.shared.endReceivingRemoteControlEvents()
    }

    /// Removes the targets `addRemoteCommandCenterHandlers()` added, each from
    /// its own command (the tokens `addTarget` returned).
    func removeRemoteCommandCenterTargets() {
        for registration in remoteCommandTargets {
            registration.command.removeTarget(registration.target)
        }
        remoteCommandTargets.removeAll()
    }
    
    func configureNowPlayingInfo() {
        nowPlayingInfo = [MPMediaItemPropertyTitle: media.title,
                          MPMediaItemPropertyPlaybackDuration: TimeInterval(streamDuration/1000),
                          MPNowPlayingInfoPropertyElapsedPlaybackTime: (mediaplayer.time.value?.doubleValue ?? 0)/1000,
                          MPNowPlayingInfoPropertyPlaybackRate: Double(mediaplayer.rate),
                          MPMediaItemPropertyMediaType: MPMediaType.movie.rawValue]
        
        if let image = media.mediumCoverImage ?? media.mediumBackgroundImage, let request = try? URLRequest(url: image, method: .get) {
            ImageDownloader.default.download(request, completion: { [weak self] response in
                // Closed meanwhile: the shared Now Playing info is no longer
                // this player's (cleared, or a later session's).
                guard let self = self, !self.isClosing, case .success(let image) = response.result else { return }
                self.nowPlayingInfo?[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            })
        }
    }
    
    override func remoteControlReceived(with event: UIEvent?) {
        guard let event = event else { return }
        
        switch event.subtype {
            case .remoteControlPlay:
                fallthrough
            case .remoteControlPause:
                fallthrough
            case .remoteControlTogglePlayPause:
                playandPause()
            case .remoteControlStop:
                mediaplayer.stop()
            default:
                break
        }
    }
}
