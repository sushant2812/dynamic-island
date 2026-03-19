import Foundation

final class SpotifyNowPlayingProvider {
    private let runner = AppleScriptRunner()

    func fetch() -> AudioSession? {
        let script = """
        tell application "Spotify"
          set pState to player state as string
          set tName to ""
          set tArtist to ""
          set tArtworkURL to ""
          try
            set tName to name of current track
            set tArtist to artist of current track
          end try
          try
            set tArtworkURL to artwork url of current track
          end try
          return pState & "||" & tName & "||" & tArtist & "||" & tArtworkURL
        end tell
        """

        guard let raw = try? runner.run(script), !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "||")
        let state = parts.first ?? "stopped"
        let title = (parts.count > 1 ? parts[1] : "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (parts.count > 2 ? parts[2] : "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artworkURLString = (parts.count > 3 ? parts[3] : "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard state == "playing" || state == "paused" else { return nil }
        guard !title.isEmpty else { return nil }

        let playback: PlaybackState = (state == "playing") ? .playing : .paused
        let artworkURL = artworkURLString.isEmpty ? nil : URL(string: artworkURLString)
        return AudioSession(
            title: title,
            subtitle: artist.isEmpty ? nil : artist,
            artworkURL: artworkURL,
            source: .spotify,
            playback: playback,
            canPlayPause: true
        )
    }

    func togglePlayPause() {
        let script = """
        tell application "System Events"
          if (name of processes) does not contain "Spotify" then return
        end tell
        tell application "Spotify" to playpause
        """
        _ = try? runner.run(script)
    }

    func previousTrack() {
        let script = """
        tell application "System Events"
          if (name of processes) does not contain "Spotify" then return
        end tell
        tell application "Spotify" to previous track
        """
        _ = try? runner.run(script)
    }

    func nextTrack() {
        let script = """
        tell application "System Events"
          if (name of processes) does not contain "Spotify" then return
        end tell
        tell application "Spotify" to next track
        """
        _ = try? runner.run(script)
    }
}
