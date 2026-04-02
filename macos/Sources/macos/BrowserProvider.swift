import Foundation

final class BrowserProvider {
    private let runner = AppleScriptRunner()
    private(set) var mediaTabURL: String?

    let browserName: String
    let processName: String

    init(browserName: String, processName: String? = nil) {
        self.browserName = browserName
        self.processName = processName ?? browserName
    }

    var source: NowPlayingSource { .browser(name: browserName) }

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
      var elems = document.querySelectorAll('video, audio');
      try {
        window.__dynIslandMedia = window.__dynIslandMedia || {};
        var store = window.__dynIslandMedia;
        var now = Date.now();

        var maxCt = 0;
        var audibleAtMax = false;

        for (var i = 0; i < elems.length; i++) {
          var e = elems[i];
          var ct = e && e.currentTime;
          if (ct == null) continue;
          ct = Number(ct) || 0;
          if (ct <= 0) continue;

          var audible = !(e.muted || e.volume === 0);
          if (ct > maxCt) {
            maxCt = ct;
            audibleAtMax = audible;
          }
        }

        var prevMain = store.__main;
        store.__main = { ct: maxCt, t: now };

        if (prevMain && maxCt > 0 && audibleAtMax) {
          var delta = maxCt - prevMain.ct;
          var dt = now - prevMain.t;
          if (dt < 20000 && delta > 0.02) { state = 'playing'; }
          else if (state === 'none') { state = 'paused'; }
        } else if (state === 'none' && maxCt > 0) {
          state = 'paused';
        }
      } catch (e) {}
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

    private static let mediaDomains = [
        "open.spotify.com", "youtube.com", "music.youtube.com",
        "netflix.com", "twitch.tv", "soundcloud.com",
        "music.apple.com", "pandora.com", "tidal.com",
        "deezer.com", "amazon.com/music", "primevideo.com",
        "disneyplus.com", "hulu.com", "hbomax.com",
    ]

    func fetch() -> AudioSession? {
        let domainChecks = Self.mediaDomains
            .map { "tURL contains \"\($0)\"" }
            .joined(separator: " or ")

        let script = """
        tell application "\(browserName)"
          if (count of windows) is 0 then return ""
          set jsCode to "\(mediaJS)"

          set bestPaused to ""

          try
            set jr to (execute active tab of front window javascript jsCode)
            if jr contains "playing||" then return jr
            if jr contains "paused||" and bestPaused is "" then set bestPaused to jr
          end try

          set scanned to 0
          repeat with t in tabs of front window
            set tURL to URL of t
            if \(domainChecks) then
              try
                set jr to (execute t javascript jsCode)
                if jr contains "playing||" then return jr
                if bestPaused is "" and jr contains "paused||" then set bestPaused to jr
              end try
            end if
            set scanned to scanned + 1
            if scanned > 6 then exit repeat
          end repeat

          return bestPaused
        end tell
        """

        guard let result = try? runner.run(script).trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty else { return nil }

        let parts = result.components(separatedBy: "||")
        let trimQuotes: (String) -> String = { s in
            s.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }

        let state = trimQuotes(parts.first ?? "none")
        guard state == "playing" || state == "paused" else { return nil }

        let title = (parts.count > 1 ? trimQuotes(parts[1]) : "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (parts.count > 2 ? trimQuotes(parts[2]) : "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artworkStr = (parts.count > 3 ? trimQuotes(parts[3]) : "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tabURL = (parts.count > 4 ? trimQuotes(parts[4]) : "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artworkURL = artworkStr.isEmpty ? nil : URL(string: artworkStr)
        let playback: PlaybackState = (state == "playing") ? .playing : .paused

        if !tabURL.isEmpty { mediaTabURL = tabURL }

        return AudioSession(
            title: title.isEmpty ? browserName : title,
            subtitle: artist.isEmpty ? nil : artist,
            artworkURL: artworkURL,
            source: source,
            playback: playback,
            canPlayPause: true
        )
    }

    /// Runs `fetch()` on a background thread and waits up to `timeout` seconds.
    /// If the browser automation hangs, we return `(nil, true)` and let callers skip it.
    func fetchWithTimeout(_ timeout: TimeInterval) -> (AudioSession?, Bool) {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: AudioSession? = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let r = self.fetch()
            lock.lock()
            result = r
            lock.unlock()
            semaphore.signal()
        }

        let didTimeout = semaphore.wait(timeout: .now() + timeout) == .timedOut
        if didTimeout { return (nil, true) }

        lock.lock()
        let r = result
        lock.unlock()
        return (r, false)
    }

    private var mediaTabDomain: String? {
        guard let url = mediaTabURL, let host = URL(string: url)?.host else { return nil }
        return host
    }

    private func runOnMediaTab(js: String) {
        guard let domain = mediaTabDomain else { return }
        let script = """
        tell application "\(browserName)"
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
        let js = "(function(){try{var host=(location.host||'').toLowerCase();if(host.indexOf('youtube.com')!==-1){var y=document.querySelector('.ytp-play-button');if(y){y.click();return 'yt'}}if(host.indexOf('open.spotify.com')!==-1){var s=document.querySelector('[data-testid=control-button-playpause]');if(s){s.click();return 'sp'}};var bs=document.querySelectorAll('button');for(var i=0;i<bs.length;i++){var l=(bs[i].getAttribute('aria-label')||'').toLowerCase();if(l.indexOf('pause')===0||l.indexOf('play')===0){bs[i].click();return 'btn'}};var m=document.querySelector('video,audio');if(m){if(m.paused){var p=m.play();if(p&&p.catch){p.catch(function(){})}}else{m.pause()};return 'media'};return 'none'}catch(e){return 'err'}})()"
        runOnMediaTab(js: js)
    }

    func previousTrack() {
        let js = "(function(){try{var bs=document.querySelectorAll('button');for(var i=0;i<bs.length;i++){var l=(bs[i].getAttribute('aria-label')||'').toLowerCase();if(l.indexOf('previous')===0||l.indexOf('skip back')===0){bs[i].click();return 'ok'}};var m=document.querySelector('video,audio');if(m){m.currentTime=Math.max(0,m.currentTime-10);return 'seek'};return 'none'}catch(e){return 'err'}})()"
        runOnMediaTab(js: js)
    }

    func nextTrack() {
        let js = "(function(){try{var bs=document.querySelectorAll('button');for(var i=0;i<bs.length;i++){var l=(bs[i].getAttribute('aria-label')||'').toLowerCase();if(l.indexOf('next')===0||l.indexOf('skip forward')===0){bs[i].click();return 'ok'}};var m=document.querySelector('video,audio');if(m){m.currentTime=m.currentTime+10;return 'seek'};return 'none'}catch(e){return 'err'}})()"
        runOnMediaTab(js: js)
    }
}
