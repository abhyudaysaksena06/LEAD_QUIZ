import { useCallback, useEffect, useRef, useState } from 'react'

// Screen control. A web page cannot stop the OS from switching apps — so we
// (1) lock the keyboard in fullscreen where the browser allows it (Chrome/Edge:
//     Alt+Tab, Win key, Esc are captured; Esc must be HELD to leave fullscreen),
// (2) detect every way of leaving the exam and report it to the server,
// (3) hide the questions whenever the exam window isn't fullscreen + focused.

const BLUR_GRACE_MS = 1500

function isEditorTarget(t) {
  return t && t.classList && t.classList.contains('code-input')
}

export async function enterFullscreen() {
  const el = document.documentElement
  if (!document.fullscreenElement) {
    // Some embedded/locked-down browsers never settle this promise. Don't let a
    // student hang on "Starting…" forever — fail after 4s so they get a message.
    await Promise.race([
      el.requestFullscreen({ navigationUI: 'hide' }),
      new Promise((_, reject) => setTimeout(() => reject(new Error('FULLSCREEN_TIMEOUT')), 4000)),
    ])
    if (!document.fullscreenElement) throw new Error('FULLSCREEN_DENIED')
  }
  // fire-and-forget: unsupported browsers still get full detection
  navigator.keyboard?.lock?.().catch(() => {})
}

export default function useProctor({ active, onFlag, onNotice }) {
  const [isFullscreen, setIsFullscreen] = useState(Boolean(document.fullscreenElement))
  const [isFocused, setIsFocused] = useState(document.hasFocus())
  const [shield, setShield] = useState(false)
  const blurTimer = useRef(null)
  const flagRef = useRef(onFlag)
  const noticeRef = useRef(onNotice)
  flagRef.current = onFlag
  noticeRef.current = onNotice

  const flag = useCallback((kind, detail) => flagRef.current?.(kind, detail), [])

  // Focus state drives the hide-the-questions UI. Tracked ALWAYS (not only while armed),
  // so arming never starts from a stale value. The 1s resync catches focus changes
  // that fire no event (OS dialogs, some window managers).
  useEffect(() => {
    const sync = () => setIsFocused(document.hasFocus())
    window.addEventListener('focus', sync)
    window.addEventListener('blur', sync)
    const t = setInterval(sync, 1000)
    return () => {
      window.removeEventListener('focus', sync)
      window.removeEventListener('blur', sync)
      clearInterval(t)
    }
  }, [])

  useEffect(() => {
    const onFs = () => {
      const fs = Boolean(document.fullscreenElement)
      setIsFullscreen(fs)
      if (!fs && active) flag('FULLSCREEN_EXIT')
    }
    document.addEventListener('fullscreenchange', onFs)
    return () => document.removeEventListener('fullscreenchange', onFs)
  }, [active, flag])

  useEffect(() => {
    if (!active) return

    const onVisibility = () => { if (document.hidden) flag('TAB_HIDDEN') }
    const onBlur = () => {
      clearTimeout(blurTimer.current)
      blurTimer.current = setTimeout(() => {
        if (!document.hasFocus()) flag('WINDOW_BLUR')
      }, BLUR_GRACE_MS)
    }
    const onFocus = () => clearTimeout(blurTimer.current)

    const onKey = e => {
      const k = e.key
      const ctrl = e.ctrlKey || e.metaKey
      const inEditor = isEditorTarget(e.target)

      if (k === 'PrintScreen') {
        setShield(true); setTimeout(() => setShield(false), 1500)
        try { navigator.clipboard?.writeText('') } catch { /* ignore */ }
        flag('PRINTSCREEN')
        return
      }
      const blocked =
        k === 'F12' || k === 'F5' || k === 'F11' ||
        (ctrl && e.shiftKey && ['I', 'J', 'C', 'K', 'i', 'j', 'c', 'k'].includes(k)) ||
        (ctrl && ['u', 's', 'p', 'r', 'f', 'g', 'h', 'U', 'S', 'P', 'R', 'F', 'G', 'H'].includes(k)) ||
        (ctrl && !inEditor && ['c', 'x', 'v', 'a', 'C', 'X', 'V', 'A'].includes(k)) ||
        (e.metaKey && e.shiftKey && ['3', '4', '5'].includes(k)) ||
        (e.altKey && k === 'Tab')
      if (blocked) {
        e.preventDefault(); e.stopPropagation()
        noticeRef.current?.('That shortcut is disabled during the test.')
      }
    }

    const stopUnlessEditor = e => { if (!isEditorTarget(e.target)) e.preventDefault() }
    const onContext = e => e.preventDefault()
    const onBeforeUnload = e => { e.preventDefault(); e.returnValue = '' }

    document.addEventListener('visibilitychange', onVisibility)
    window.addEventListener('blur', onBlur)
    window.addEventListener('focus', onFocus)
    document.addEventListener('keydown', onKey, true)
    document.addEventListener('copy', stopUnlessEditor, true)
    document.addEventListener('cut', stopUnlessEditor, true)
    document.addEventListener('paste', stopUnlessEditor, true)
    document.addEventListener('contextmenu', onContext)
    document.addEventListener('dragstart', onContext)
    window.addEventListener('beforeunload', onBeforeUnload)

    return () => {
      clearTimeout(blurTimer.current)
      document.removeEventListener('visibilitychange', onVisibility)
      window.removeEventListener('blur', onBlur)
      window.removeEventListener('focus', onFocus)
      document.removeEventListener('keydown', onKey, true)
      document.removeEventListener('copy', stopUnlessEditor, true)
      document.removeEventListener('cut', stopUnlessEditor, true)
      document.removeEventListener('paste', stopUnlessEditor, true)
      document.removeEventListener('contextmenu', onContext)
      document.removeEventListener('dragstart', onContext)
      window.removeEventListener('beforeunload', onBeforeUnload)
    }
  }, [active, flag])

  return { isFullscreen, isFocused, shield }
}

export function releaseScreen() {
  try { navigator.keyboard?.unlock?.() } catch { /* ignore */ }
  if (document.fullscreenElement) document.exitFullscreen().catch(() => {})
}
