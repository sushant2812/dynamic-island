import React, { useEffect, useMemo, useRef, useState } from 'react'

function AppIcon({ source }: { source: 'spotify' | 'chrome' | 'unknown' }) {
  if (source === 'spotify') {
    return (
      <svg className="appIcon" viewBox="0 0 24 24" aria-label="Spotify" role="img">
        <path
          fill="currentColor"
          d="M12 2.2c-5.41 0-9.8 4.39-9.8 9.8 0 5.41 4.39 9.8 9.8 9.8 5.41 0 9.8-4.39 9.8-9.8 0-5.41-4.39-9.8-9.8-9.8Zm4.52 14.12a.85.85 0 0 1-1.17.28c-3.2-1.96-7.23-2.4-11.99-1.31a.85.85 0 1 1-.38-1.66c5.22-1.2 9.72-.7 13.33 1.51.4.24.52.77.28 1.18Zm1.17-2.6a1.07 1.07 0 0 1-1.47.35c-3.67-2.25-9.27-2.9-13.62-1.58a1.07 1.07 0 0 1-.62-2.05c4.96-1.5 11.12-.78 15.34 1.8.5.3.66.97.37 1.48Zm.1-2.72C13.4 8.4 7.03 8.22 3.2 9.38a1.28 1.28 0 0 1-.74-2.45C6.86 5.6 14.17 5.84 19.1 8.8a1.28 1.28 0 0 1-1.32 2.2Z"
        />
      </svg>
    )
  }

  if (source === 'chrome') {
    return (
      <svg className="appIcon" viewBox="0 0 24 24" aria-label="Chrome" role="img">
        <path
          fill="currentColor"
          d="M12 2.2c-2.39 0-4.56.88-6.23 2.32h9.12c1.06 0 1.97.55 2.5 1.38l1.74 3.02A9.72 9.72 0 0 0 12 2.2Zm-7.84 4.1A9.77 9.77 0 0 0 2.2 12c0 3.84 2.22 7.17 5.45 8.78l-4.3-7.45a2.92 2.92 0 0 1 0-2.92l.8-1.38Zm7.84 3.2a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5Zm8.58.54-4.04 7a2.9 2.9 0 0 1-2.52 1.46H10.6l-3.46 5.99A9.75 9.75 0 0 0 12 21.8c5.41 0 9.8-4.39 9.8-9.8 0-.68-.07-1.34-.2-1.96Z"
        />
      </svg>
    )
  }

  return (
    <div className="appIconFallback" aria-label="Unknown source">
      •
    </div>
  )
}

export function App() {
  const [expanded, setExpanded] = useState(false)
  const rootRef = useRef<HTMLDivElement | null>(null)

  useEffect(() => {
    // Click-through window by default; enable interactivity only while hovering UI.
    const el = rootRef.current
    if (!el) return

    const onEnter = () => void window.island?.setInteractive(true)
    const onLeave = () => void window.island?.setInteractive(false)

    el.addEventListener('mouseenter', onEnter)
    el.addEventListener('mouseleave', onLeave)

    // Default state: click-through until hovered.
    void window.island?.setInteractive(false)

    return () => {
      el.removeEventListener('mouseenter', onEnter)
      el.removeEventListener('mouseleave', onLeave)
    }
  }, [])

  const nowPlaying = useMemo(() => {
    return {
      title: 'Nothing playing',
      subtitle: 'We’ll wire macOS Now Playing next',
      source: 'spotify' as 'spotify' | 'chrome' | 'unknown',
      state: 'idle' as 'idle' | 'playing' | 'paused',
    }
  }, [])

  return (
    <div className="topStrip" ref={rootRef}>
      <button
        type="button"
        className={expanded ? 'pill pillExpanded' : 'pill pillCollapsed pillIconOnly'}
        onClick={async () => {
          const next = !expanded
          setExpanded(next)
          await window.island?.setExpanded(next)
        }}
        aria-expanded={expanded}
      >
        {expanded ? (
          <div className="pillLeft">
            <AppIcon source={nowPlaying.source} />
            <div className={nowPlaying.state === 'playing' ? 'dot dotPlaying' : 'dot'} />
            <div className="text">
              <div className="title">{nowPlaying.title}</div>
              <div className="subtitle">{nowPlaying.subtitle}</div>
            </div>
          </div>
        ) : (
          <div className="pillIconOnlyInner">
            <AppIcon source={nowPlaying.source} />
          </div>
        )}

        {expanded ? (
          <div className="pillRight">
            <div className="chip">Notifications</div>
            <div className="chip">Input device</div>
          </div>
        ) : null}
      </button>

      {expanded ? (
        <div className="panel">
          <div className="panelCard">
            <div className="panelTitle">Expanded panel</div>
            <div className="panelSub">This area will show notifications + input device switcher next.</div>
          </div>
        </div>
      ) : null}
    </div>
  )
}

