export {}

declare global {
  interface Window {
    island?: {
      setExpanded: (expanded: boolean) => Promise<{ expanded: boolean }>
      setInteractive: (interactive: boolean) => Promise<{ interactive: boolean }>
    }
  }
}

