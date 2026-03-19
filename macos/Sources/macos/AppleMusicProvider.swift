import Foundation

final class AppleMusicNowPlayingProvider {
    private let runner = AppleScriptRunner()
    private var lastArtworkTrack: String?
    private var cachedArtworkURL: URL?

    func fetch() -> AudioSession? {
        let script = """
        tell application "System Events"
          if (name of processes) does not contain "Music" then return ""
        end tell
        tell application "Music"
          if player state is stopped then return ""
          set pState to "playing"
          if player state is paused then set pState to "paused"
          set tName to ""
          set tArtist to ""
          set tAlbum to ""
          try
            set tName to name of current track
            set tArtist to artist of current track
            set tAlbum to album of current track
          end try
          return pState & "||" & tName & "||" & tArtist & "||" & tAlbum
        end tell
        """

        guard let raw = try? runner.run(script), !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "||")
        let state = parts.first ?? "stopped"
        let title = (parts.count > 1 ? parts[1] : "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (parts.count > 2 ? parts[2] : "").trimmingCharacters(in: .whitespacesAndNewlines)
        let album = (parts.count > 3 ? parts[3] : "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard state == "playing" || state == "paused" else { return nil }
        guard !title.isEmpty else { return nil }

        let trackKey = "\(title)—\(artist)"
        if trackKey != lastArtworkTrack {
            lastArtworkTrack = trackKey
            cachedArtworkURL = lookupArtworkURL(title: title, artist: artist, album: album)
        }

        let playback: PlaybackState = (state == "playing") ? .playing : .paused
        return AudioSession(
            title: title,
            subtitle: artist.isEmpty ? nil : artist,
            artworkURL: cachedArtworkURL,
            source: .appleMusic,
            playback: playback,
            canPlayPause: true
        )
    }

    private func sanitizeForSearch(_ text: String) -> String {
        text.replacingOccurrences(of: "$", with: "S")
            .replacingOccurrences(of: "&", with: " ")
            .replacingOccurrences(of: "*", with: "")
    }

    private func lookupArtworkURL(title: String, artist: String, album: String) -> URL? {
        let cleanArtist = sanitizeForSearch(artist)
        var queries = ["\(title) \(cleanArtist)"]
        if !album.isEmpty { queries.append("\(album) \(cleanArtist)") }
        queries.append(title)

        for q in queries {
            guard let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let searchURL = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=song&limit=5") else {
                continue
            }
            guard let data = try? Data(contentsOf: searchURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  !results.isEmpty else {
                continue
            }
            let match = results.first(where: {
                let a = ($0["artistName"] as? String ?? "").lowercased()
                return a.contains(artist.components(separatedBy: " ").first?.lowercased() ?? "")
            }) ?? results.first
            if let artworkStr = match?["artworkUrl100"] as? String {
                let highRes = artworkStr.replacingOccurrences(of: "100x100bb", with: "600x600bb")
                return URL(string: highRes)
            }
        }
        return nil
    }

    func togglePlayPause() {
        let script = """
        tell application "System Events"
          if (name of processes) does not contain "Music" then return
        end tell
        tell application "Music" to playpause
        """
        _ = try? runner.run(script)
    }

    func previousTrack() {
        let script = """
        tell application "System Events"
          if (name of processes) does not contain "Music" then return
        end tell
        tell application "Music" to previous track
        """
        _ = try? runner.run(script)
    }

    func nextTrack() {
        let script = """
        tell application "System Events"
          if (name of processes) does not contain "Music" then return
        end tell
        tell application "Music" to next track
        """
        _ = try? runner.run(script)
    }
}
