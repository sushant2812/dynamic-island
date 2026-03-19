import Foundation

final class ChromeNowPlayingProvider {
    private let runner = AppleScriptRunner()
    private(set) var mediaTabURL: String?

    private let mediaJS = """
    (function() {
      var state = 'none', title = '', artist = '', artwork = '';
      try {
        var ms = navigator.mediaSession;
        if (ms && ms.playbackState === 'playing') state = 'playing';
        else if (ms && ms.playbackState === 'paused') state = 'paused';
        if (ms && ms.metadata) {
          title = ms.metadata.title || '';
          artist = ms.metadata.artist || '';
        }
      } catch(e) {}
      try {
        var md = navigator.mediaSession && navigator.mediaSession.metadata;
        if (md && md.artwork && md.artwork.length > 0) artwork = md.artwork[md.artwork.length - 1].src || '';
      } catch(e) {}
      if (state === 'none') {
        var elems = document.querySelectorAll('video, audio');
        for (var i = 0; i < elems.length; i++) {
          var e = elems[i];
          if (e.muted || e.volume === 0) continue;
          if (!e.paused && e.currentTime > 0) { state = 'playing'; break; }
        }
        if (state === 'none') {
          for (var j = 0; j < elems.length; j++) {
            var el = elems[j];
            if (!el.paused && el.currentTime > 0) { state = 'playing'; break; }
            if (el.paused && el.currentTime > 0) { state = 'paused'; break; }
          }
        }
      }
      if (state === 'none' && location.host === 'open.spotify.com') {
        var btn = document.querySelector('[data-testid=control-button-playpause]');
        if (btn) {
          var lbl = (btn.getAttribute('aria-label') || '').toLowerCase();
          if (lbl.indexOf('pause') !== -1) state = 'playing';
          else if (lbl.indexOf('play') !== -1) state = 'paused';
        }
      }
      if (state === 'none' && title) state = 'paused';
      if (!title) title = document.title || '';
      return state + '||' + title + '||' + artist + '||' + artwork + '||' + location.href;
    })();
    """

    func fetchActiveTabTitle() -> AudioSession? {
        let script = """
        tell application "System Events"
          if (name of processes) does not contain "Google Chrome" then return ""
        end tell
        tell application "Google Chrome"
          if (count of windows) is 0 then return ""
          set jsCode to "\(mediaJS)"

          set bestPaused to ""

          -- 1. Try the active tab first (fast path for playing).
          try
            set jr to (execute active tab of front window javascript jsCode)
            if jr starts with "playing" then return jr
            if jr starts with "paused" and bestPaused is "" then set bestPaused to jr
          end try

          -- 2. Scan background tabs on known media domains.
          --    A "playing" tab always wins; otherwise keep first "paused".
          repeat with t in tabs of front window
            set tURL to URL of t
            if tURL contains "open.spotify.com" or tURL contains "youtube.com" or tURL contains "music.youtube.com" or tURL contains "netflix.com" or tURL contains "twitch.tv" or tURL contains "soundcloud.com" then
              try
                set jr to (execute t javascript jsCode)
                if jr starts with "playing" then return jr
                if bestPaused is "" and jr starts with "paused" then set bestPaused to jr
              end try
            end if
          end repeat

          return bestPaused
        end tell
        """

        guard let result = try? runner.run(script).trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty else { return nil }

        let parts = result.components(separatedBy: "||")
        let state = parts.first ?? "none"
        guard state == "playing" || state == "paused" else { return nil }

        let title = (parts.count > 1 ? parts[1] : "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (parts.count > 2 ? parts[2] : "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artworkStr = (parts.count > 3 ? parts[3] : "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tabURL = (parts.count > 4 ? parts[4] : "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artworkURL = artworkStr.isEmpty ? nil : URL(string: artworkStr)
        let playback: PlaybackState = (state == "playing") ? .playing : .paused

        if !tabURL.isEmpty { mediaTabURL = tabURL }

        return AudioSession(
            title: title.isEmpty ? "Chrome" : title,
            subtitle: artist.isEmpty ? nil : artist,
            artworkURL: artworkURL,
            source: .chrome,
            playback: playback,
            canPlayPause: true
        )
    }

    private var mediaTabDomain: String? {
        guard let url = mediaTabURL, let host = URL(string: url)?.host else { return nil }
        return host
    }

    private func runOnMediaTab(js: String) {
        guard let domain = mediaTabDomain else { return }
        let script = """
        tell application "Google Chrome"
          if (count of windows) is 0 then return
          repeat with w in windows
            repeat with t in tabs of w
              if URL of t contains "\(domain)" then
                execute t javascript "\(js)"
                return "ok"
              end if
            end repeat
          end repeat
        end tell
        """
        _ = try? runner.run(script)
    }

    func togglePlayPause() {
        let js = "(function(){try{var bs=document.querySelectorAll('button');for(var i=0;i<bs.length;i++){var l=(bs[i].getAttribute('aria-label')||'').toLowerCase();if(l==='play'||l==='pause'){bs[i].click();return 'ok'}};var m=document.querySelector('video,audio');if(m){if(m.paused){m.play()}else{m.pause()};return 'media'};return 'none'}catch(e){return 'err'}})()"
        runOnMediaTab(js: js)
    }

    func previousTrack() {
        let js = "(function(){try{var bs=document.querySelectorAll('button');for(var i=0;i<bs.length;i++){var l=(bs[i].getAttribute('aria-label')||'').toLowerCase();if(l==='previous'||l==='skip back'){bs[i].click();return 'ok'}};var m=document.querySelector('video,audio');if(m){m.currentTime=Math.max(0,m.currentTime-10);return 'seek'};return 'none'}catch(e){return 'err'}})()"
        runOnMediaTab(js: js)
    }

    func nextTrack() {
        let js = "(function(){try{var bs=document.querySelectorAll('button');for(var i=0;i<bs.length;i++){var l=(bs[i].getAttribute('aria-label')||'').toLowerCase();if(l==='next'||l==='skip forward'){bs[i].click();return 'ok'}};var m=document.querySelector('video,audio');if(m){m.currentTime=m.currentTime+10;return 'seek'};return 'none'}catch(e){return 'err'}})()"
        runOnMediaTab(js: js)
    }
}
