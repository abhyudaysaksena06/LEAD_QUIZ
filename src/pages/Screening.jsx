import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { rpc, store } from '../lib/api'
import { firebaseConfigured, googleIdToken } from '../lib/firebase'

const fullscreenSupported = () => typeof document !== 'undefined' && document.fullscreenEnabled &&
  typeof document.documentElement.requestFullscreen === 'function'
const enterFullscreen = () => {
  if (!fullscreenSupported() || document.fullscreenElement) return Promise.resolve()
  return document.documentElement.requestFullscreen({ navigationUI: 'hide' }).catch(() => {})
}

/**
 * PRIMUS 2026 screening round — the team leader's page.
 *
 *   sign in / create account (any email + password)
 *     → complete sign-in: leader's name + mobile, team name, one track
 *     → Start: the case and the track's three prompts appear, server-side timer runs
 *     → answers autosave; Submit, or the clock closes it at 0:00
 *
 * Every rule (one team per account, unique team names and phone numbers, the track lock
 * after Start, the deadline) is enforced by the database; this page shows what it returns.
 */
const SESSION_KEY = 'primus-leader'

export default function Screening() {
  const [session, setSession] = useState(() => store.get(SESSION_KEY))   // { token, email }
  const [data, setData] = useState(null)        // screening_state() payload
  const [editing, setEditing] = useState(false) // changing details before Start
  const [error, setError] = useState('')
  const offset = useRef(0)
  const token = session?.token

  const accept = useCallback(d => {
    offset.current = new Date(d.server_now) - Date.now()
    setData(d); setError('')
  }, [])

  const signOut = useCallback(async (callServer = true) => {
    const t = store.get(SESSION_KEY)?.token
    store.del(SESSION_KEY)
    setSession(null); setData(null); setEditing(false)
    if (callServer && t) { try { await rpc('screening_logout', { p_token: t }) } catch { /* ignore */ } }
  }, [])

  const load = useCallback(async () => {
    if (!token) return
    try { accept(await rpc('screening_state', { p_token: token })) }
    catch (e) {
      if (e.code === 'SESSION_INVALID') { signOut(false); setError(e.message) }
      else setError(e.message)
    }
  }, [token, accept, signOut])

  useEffect(() => { load() }, [load])

  function signedIn(s) {
    store.set(SESSION_KEY, { token: s.token, email: s.email })
    setSession({ token: s.token, email: s.email })
  }

  if (!token) return (
    <ScreeningShell>
      <AuthCard onSignedIn={signedIn} notice={error} />
    </ScreeningShell>
  )

  if (!data) return (
    <div className="center-page">
      {error ? <div className="card narrow"><div className="error">{error}</div>
        <button onClick={load}>Try again</button>{' '}
        <button className="ghost" onClick={() => signOut()}>Sign out</button></div>
        : <p className="muted">Loading…</p>}
    </div>
  )

  const team = data.team
  const cfg = data.config

  if (team?.status === 'writing') return (
    <Writing token={token} data={data} offset={offset} onState={accept} onReload={load} />
  )

  if (team?.status === 'submitted') return (
    <ScreeningShell cfg={cfg}>
      <Done data={data} onSignOut={signOut} />
    </ScreeningShell>
  )

  // signed in: complete the details, or wait to start
  return (
    <ScreeningShell cfg={cfg}>
      {!team || editing
        ? <DetailsForm token={token} data={data} onSaved={d => { accept(d); setEditing(false) }}
                       onCancel={team ? () => setEditing(false) : null} onSignOut={signOut} />
        : <ReadyCard token={token} data={data} onEdit={() => setEditing(true)} onStarted={accept}
                     onSignOut={signOut} />}
      {error && <div className="error">{error}</div>}
    </ScreeningShell>
  )
}

/** Rules on the left, the action on the right. */
function ScreeningShell({ cfg, children }) {
  const mins = cfg?.duration_minutes ?? 15
  return (
    <div className="split-page">
      <section className="split-left card">
        <div className="brand-mark">{cfg?.event_title || 'PRIMUS 2026 · Screening Round'}</div>
        <h1>{cfg?.case_title || 'Case File 07: The Ghost Customer'}</h1>
        <p className="muted">A {mins}-minute written case sprint. Read this before you start.</p>
        <ul className="rules">
          <li><b>Only the team leader signs in</b>, with any email address and a password.
            Each account submits <b>one response for one team</b>.</li>
          <li>To complete sign-in, enter the <b>team leader’s full name</b> and <b>mobile number</b>,
            your <b>team name</b>, and choose <b>one track</b>:
            <ul className="sub-rules">
              <li><b>Product</b> — product &amp; commercial offering strategy</li>
              <li><b>Consulting</b> — strategy, operations &amp; crisis governance</li>
              <li><b>Finance</b> — corporate finance &amp; valuation</li>
            </ul>
            You can change these until you press Start. After that they are locked.</li>
          <li>Every track works on the same case. The case file and your track’s
            {' '}<b>three prompts</b> appear only when you press <b>Start</b>.</li>
          <li><b>Your {mins}-minute timer starts the moment you press Start</b> and does not pause —
            closing or refreshing the page does not stop it.</li>
          <li>Answers <b>save automatically</b> every few seconds. When the timer reaches 0:00 your
            response is submitted with whatever has been saved.</li>
          <li>Answer all three prompts. Bullet points are fine.</li>
          <li><b>The sprint runs in fullscreen.</b> If you leave fullscreen the answers are hidden
            until you return; the timer keeps running.</li>
          <li><b>Write your own answers.</b> During the sprint, <b>copying, cutting, pasting and the
            right-click menu are disabled</b>. Every attempt, every time you leave fullscreen, and every
            time you leave the tab or window is recorded and shown to the organisers.</li>
          <li>Use a laptop, and keep the response open in <b>one tab only</b>.</li>
        </ul>
      </section>
      <aside className="split-right">{children}</aside>
    </div>
  )
}

function AuthCard({ onSignedIn, notice }) {
  const [mode, setMode] = useState('signup')     // signup | login
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [show, setShow] = useState(false)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const signup = mode === 'signup'

  async function google() {
    setError(''); setBusy(true)
    try {
      const idToken = await googleIdToken()
      const r = await fetch('/api/google-login', { method: 'POST', headers: { 'Content-Type': 'application/json' },
                                                   body: JSON.stringify({ idToken }) })
      let body = null
      try { body = await r.json() } catch { /* not JSON */ }
      if (!r.ok || !body?.ok) throw new Error(body?.message || 'Google sign-in failed. Use email and password instead.')
      onSignedIn(body)
    } catch (err) {
      const m = String(err?.message || err?.code || '')
      if (!/popup-closed|cancelled-popup|user-cancelled/.test(m)) {
        setError(/unauthorized-domain/.test(m)
          ? 'Google sign-in is not enabled for this website yet. Use email and password, or ask the organisers.'
          : m || 'Google sign-in failed.')
      }
    } finally { setBusy(false) }
  }

  async function submit(e) {
    e.preventDefault()
    setError('')
    if (signup && password !== confirm) { setError('The two passwords do not match.'); return }
    setBusy(true)
    try {
      onSignedIn(await rpc(signup ? 'screening_signup' : 'screening_login',
                           { p_email: email.trim(), p_password: password }))
    } catch (err) {
      setError(err.message)
      if (err.code === 'EMAIL_ALREADY_REGISTERED') setMode('login')
    } finally { setBusy(false) }
  }

  return (
    <form className="card" onSubmit={submit}>
      <div className="brand-mark">PRIMUS 2026</div>
      <h1>{signup ? 'Create your account' : 'Sign in'}</h1>
      <p className="muted">Team leaders only. Use any email address you can be reached on.</p>
      {firebaseConfigured && <>
        <button type="button" className="sc-google" onClick={google} disabled={busy}>
          <svg width="18" height="18" viewBox="0 0 48 48" aria-hidden="true"><path fill="#FFC107" d="M43.6 20.5H42V20H24v8h11.3C33.7 32.7 29.2 36 24 36c-6.6 0-12-5.4-12-12s5.4-12 12-12c3.1 0 5.8 1.2 7.9 3.1l5.7-5.7C34 6.1 29.3 4 24 4 12.9 4 4 12.9 4 24s8.9 20 20 20 20-8.9 20-20c0-1.3-.1-2.4-.4-3.5z"/><path fill="#FF3D00" d="m6.3 14.7 6.6 4.8C14.7 15.1 19 12 24 12c3.1 0 5.8 1.2 7.9 3.1l5.7-5.7C34 6.1 29.3 4 24 4 16.3 4 9.7 8.3 6.3 14.7z"/><path fill="#4CAF50" d="M24 44c5.2 0 9.9-2 13.4-5.2l-6.2-5.2C29.2 35.1 26.7 36 24 36c-5.2 0-9.6-3.3-11.3-8l-6.5 5C9.5 39.6 16.2 44 24 44z"/><path fill="#1976D2" d="M43.6 20.5H42V20H24v8h11.3c-.8 2.2-2.2 4.2-4.1 5.6l6.2 5.2C37 39.2 44 34 44 24c0-1.3-.1-2.4-.4-3.5z"/></svg>
          {busy ? 'Please wait…' : 'Continue with Google'}
        </button>
        <div className="sc-or"><span>or use email and password</span></div>
      </>}
      <div className="sc-modes" role="tablist">
        <button type="button" role="tab" aria-selected={signup} className={signup ? 'active' : ''}
                onClick={() => { setMode('signup'); setError('') }}>New team leader</button>
        <button type="button" role="tab" aria-selected={!signup} className={!signup ? 'active' : ''}
                onClick={() => { setMode('login'); setError('') }}>I have an account</button>
      </div>
      {notice && !error && <div className="error">{notice}</div>}

      <label htmlFor="em">Email</label>
      <input id="em" type="email" value={email} onChange={e => setEmail(e.target.value)}
             autoComplete="email" maxLength={254} required autoFocus />
      <label htmlFor="pw">Password</label>
      <input id="pw" type={show ? 'text' : 'password'} value={password} onChange={e => setPassword(e.target.value)}
             autoComplete={signup ? 'new-password' : 'current-password'} minLength={signup ? 8 : 1} maxLength={72} required />
      {signup && <>
        <label htmlFor="pw2">Confirm password</label>
        <input id="pw2" type={show ? 'text' : 'password'} value={confirm} onChange={e => setConfirm(e.target.value)}
               autoComplete="new-password" minLength={8} maxLength={72} required />
      </>}
      <label className="sc-check">
        <input type="checkbox" checked={show} onChange={e => setShow(e.target.checked)} /> Show password
      </label>
      {signup && <p className="small muted" style={{ margin: '6px 0 0' }}>At least 8 characters. Remember it — you’ll need it if you sign in again.</p>}

      {error && <div className="error">{error}</div>}
      <button className="lg" style={{ width: '100%', marginTop: 14 }} disabled={busy}>
        {busy ? 'Please wait…' : signup ? 'Create account' : 'Sign in'}
      </button>
      {!signup && <p className="small muted" style={{ marginTop: 12 }}>Forgot your password? Ask an organiser to reset it.</p>}
    </form>
  )
}

function SignedInAs({ data, onSignOut }) {
  return (
    <p className="small muted" style={{ marginTop: 14 }}>
      Signed in as <b>{data.email}</b>.{' '}
      <button type="button" className="ghost sm" onClick={() => onSignOut()}>Sign out</button>
    </p>
  )
}

function DetailsForm({ token, data, onSaved, onCancel, onSignOut }) {
  const t = data.team
  const [leader, setLeader] = useState(t?.leader_name || '')
  const [phone, setPhone] = useState(t?.leader_phone || '')
  const [name, setName] = useState(t?.team_name || '')
  const [track, setTrack] = useState(t?.track || '')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const closed = !data.config.is_open

  async function submit(e) {
    e.preventDefault()
    if (!track) { setError('Choose a track.'); return }
    setError(''); setBusy(true)
    try {
      onSaved(await rpc('screening_register', { p_token: token, p_leader_name: leader, p_phone: phone,
                                                p_team_name: name, p_track: track }))
    } catch (err) { setError(err.message) }
    finally { setBusy(false) }
  }

  return (
    <form className="card" onSubmit={submit}>
      <div className="brand-mark">{t ? 'Edit details' : 'Complete sign-in'}</div>
      <h1>{t ? 'Edit your team' : 'Team leader & team'}</h1>
      {closed && <div className="error">Registration for the screening round is closed.</div>}

      <label htmlFor="ln">Team leader’s full name</label>
      <input id="ln" value={leader} onChange={e => setLeader(e.target.value)} maxLength={80}
             autoComplete="name" required disabled={closed} autoFocus />
      <label htmlFor="ph">Team leader’s mobile number</label>
      <input id="ph" type="tel" inputMode="tel" value={phone} onChange={e => setPhone(e.target.value)}
             maxLength={16} placeholder="10-digit mobile number" autoComplete="tel" required disabled={closed} />
      <label htmlFor="team">Team name</label>
      <input id="team" value={name} onChange={e => setName(e.target.value)} maxLength={60}
             placeholder="e.g. The Analysts" required disabled={closed} />

      <label>Track</label>
      <div className="sc-tracks" role="radiogroup">
        {(data.tracks || []).map(x => (
          <label key={x.id} className={`sc-track ${track === x.id ? 'selected' : ''}`}>
            <input type="radio" name="track" value={x.id} checked={track === x.id}
                   onChange={() => setTrack(x.id)} disabled={closed} />
            <span><b>{x.label}</b><span className="small muted">{x.subtitle}</span></span>
          </label>
        ))}
      </div>

      {error && <div className="error">{error}</div>}
      <div className="row" style={{ marginTop: 16 }}>
        <button className="lg" style={{ flex: 1 }} disabled={busy || closed}>
          {busy ? 'Saving…' : t ? 'Save changes' : 'Complete sign-in'}
        </button>
        {onCancel && <button type="button" className="ghost lg" onClick={onCancel}>Cancel</button>}
      </div>
      <SignedInAs data={data} onSignOut={onSignOut} />
    </form>
  )
}

function ReadyCard({ token, data, onEdit, onStarted, onSignOut }) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const t = data.team
  const mins = data.config.duration_minutes

  async function start() {
    if (!window.confirm(`Start now? Your ${mins}-minute timer begins immediately and cannot be paused. Your details and track (${t.track_label}) will be locked. The sprint opens in fullscreen.`)) return
    enterFullscreen()            // must run in the click, before anything is awaited
    setBusy(true); setError('')
    try { onStarted(await rpc('screening_start', { p_token: token })) }
    catch (err) { setError(err.message) }
    finally { setBusy(false) }
  }

  return (
    <div className="card">
      <div className="brand-mark">Ready</div>
      <h1>Ready when you are</h1>
      <dl className="details">
        <dt>Team</dt><dd>{t.team_name}</dd>
        <dt>Track</dt><dd>{t.track_label}</dd>
        <dt>Team leader</dt><dd>{t.leader_name}</dd>
        <dt>Mobile</dt><dd>{t.leader_phone}</dd>
        <dt>Time</dt><dd>{mins} minutes, 3 prompts</dd>
      </dl>
      {data.config.is_open
        ? <div className="status-box ok">You’re registered. Press Start when your team is together and ready.</div>
        : <div className="status-box wait">The screening round is not open right now. Refresh this page once the organisers open it.</div>}
      {error && <div className="error">{error}</div>}
      <button className="lg" style={{ width: '100%', marginTop: 14 }} onClick={start}
              disabled={busy || !data.config.is_open}>
        {busy ? 'Starting…' : `Start the ${mins}-minute sprint`}
      </button>
      <button type="button" className="ghost" style={{ width: '100%', marginTop: 8 }} onClick={onEdit}>
        Change details or track
      </button>
      <SignedInAs data={data} onSignOut={onSignOut} />
    </div>
  )
}

const words = s => (s.trim() ? s.trim().split(/\s+/).length : 0)

// A single change that adds more than this many characters, without a paste, is unusual for typing
// (autocorrect adds a word or two) and is recorded as a large insert.
const BULK_INSERT_CHARS = 60
const PASTE_INPUT_TYPES = new Set(['insertFromPaste', 'insertFromPasteAsQuotation', 'insertFromDrop', 'insertFromYank'])

/**
 * Copy / paste protection for the writing screen. Blocks paste, drop, copy, cut and the context
 * menu anywhere on the page, and counts the attempts plus times the leader left the tab. The counts
 * are sent to the server with the autosave and shown to the organisers. A browser cannot stop
 * someone retyping from another device — this removes the easy routes and records the rest.
 */
function useIntegrityGuard(token, active) {
  const counts = useRef({ paste: 0, copy: 0, bulk: 0, tab: 0, fullscreen: 0 })
  const [notice, setNotice] = useState('')
  const noticeTimer = useRef(null)

  const warn = useCallback(text => {
    setNotice(text)
    clearTimeout(noticeTimer.current)
    noticeTimer.current = setTimeout(() => setNotice(''), 3500)
  }, [])

  const record = useCallback((kind, text) => {
    counts.current[kind]++
    if (text) warn(text)
  }, [warn])

  // send the counts gathered since the last flush; on failure put them back for the next try
  const flush = useCallback(async () => {
    const c = counts.current
    if (!c.paste && !c.copy && !c.bulk && !c.tab && !c.fullscreen) return
    counts.current = { paste: 0, copy: 0, bulk: 0, tab: 0, fullscreen: 0 }
    try {
      await rpc('screening_report_integrity', { p_token: token, p_paste: c.paste, p_copy: c.copy, p_bulk: c.bulk,
                                                p_tab: c.tab, p_fullscreen: c.fullscreen })
    } catch {
      for (const k of Object.keys(c)) counts.current[k] += c[k]
    }
  }, [token])

  useEffect(() => {
    if (!active) return
    const block = (kind, text) => e => { e.preventDefault(); record(kind, text) }
    const onPaste = block('paste', 'Pasting is disabled in the screening round. This attempt has been recorded.')
    const onDrop = block('paste', 'Dropping text is disabled in the screening round. This attempt has been recorded.')
    const onCopy = block('copy', 'Copying is disabled in the screening round. This attempt has been recorded.')
    const onCut = block('copy', 'Cutting is disabled in the screening round. This attempt has been recorded.')
    const onDragStart = e => e.preventDefault()
    const onDragOver = e => e.preventDefault()
    const onMenu = e => { e.preventDefault(); warn('The right-click menu is disabled during the sprint.') }
    // some keyboards and extensions insert text without a paste event
    const onBeforeInput = e => {
      if (PASTE_INPUT_TYPES.has(e.inputType)) { e.preventDefault(); record('paste', 'Pasting is disabled in the screening round. This attempt has been recorded.') }
    }
    // one count per departure: a tab switch fires both blur and visibilitychange
    let away = false
    const leave = () => { if (!away) { away = true; record('tab') } }
    const back = () => {
      if (away) { away = false; warn('You left the screening tab. This is recorded and shown to the organisers.') }
    }
    const onVisibility = () => (document.hidden ? leave() : back())

    const opts = { capture: true }
    document.addEventListener('paste', onPaste, opts)
    document.addEventListener('drop', onDrop, opts)
    document.addEventListener('copy', onCopy, opts)
    document.addEventListener('cut', onCut, opts)
    document.addEventListener('dragstart', onDragStart, opts)
    document.addEventListener('dragover', onDragOver, opts)
    document.addEventListener('contextmenu', onMenu, opts)
    document.addEventListener('beforeinput', onBeforeInput, opts)
    document.addEventListener('visibilitychange', onVisibility)
    window.addEventListener('blur', leave)
    window.addEventListener('focus', back)
    const t = setInterval(flush, 3000)
    return () => {
      document.removeEventListener('paste', onPaste, opts)
      document.removeEventListener('drop', onDrop, opts)
      document.removeEventListener('copy', onCopy, opts)
      document.removeEventListener('cut', onCut, opts)
      document.removeEventListener('dragstart', onDragStart, opts)
      document.removeEventListener('dragover', onDragOver, opts)
      document.removeEventListener('contextmenu', onMenu, opts)
      document.removeEventListener('beforeinput', onBeforeInput, opts)
      document.removeEventListener('visibilitychange', onVisibility)
      window.removeEventListener('blur', leave)
      window.removeEventListener('focus', back)
      clearInterval(t)
      clearTimeout(noticeTimer.current)
      flush()
    }
  }, [active, record, warn, flush])

  const recordBulk = useCallback(() => record('bulk'), [record])

  // fullscreen: count every exit; while not in fullscreen the answers are covered (see Writing)
  const [fullscreen, setFullscreen] = useState(() => !!document.fullscreenElement)
  useEffect(() => {
    if (!active || !fullscreenSupported()) return
    const onChange = () => {
      const now = !!document.fullscreenElement
      setFullscreen(now)
      if (!now) record('fullscreen', 'You left fullscreen. This is recorded and shown to the organisers.')
    }
    document.addEventListener('fullscreenchange', onChange)
    return () => document.removeEventListener('fullscreenchange', onChange)
  }, [active, record])
  const needsFullscreen = active && fullscreenSupported() && !fullscreen

  return useMemo(() => ({ notice, recordBulk, flush, needsFullscreen }), [notice, recordBulk, flush, needsFullscreen])
}
const fmtClock = ms => {
  const s = Math.max(0, Math.ceil(ms / 1000))
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}

function Writing({ token, data, offset, onState, onReload }) {
  const draftKey = `screening-draft:${data.email}`
  // A draft typed after the last successful save (the network dropped, the tab crashed)
  // wins over the server copy, and is pushed on the first autosave.
  const [initial] = useState(() => {
    const server = data.case?.answers || ['', '', '']
    const d = store.get(draftKey)
    // server time → this device's clock: subtract the offset
    const savedAt = data.team.last_saved_at ? new Date(data.team.last_saved_at).getTime() - offset.current : 0
    const useDraft = d?.answers?.length === 3 && d.at > savedAt && d.answers.some((a, i) => a !== server[i])
    return { answers: useDraft ? d.answers : server, dirty: useDraft }
  })
  const [answers, setAnswers] = useState(initial.answers)
  const [saveState, setSaveState] = useState({ kind: 'idle', text: 'All changes saved' })
  const [left, setLeft] = useState(() => new Date(data.team.deadline) - (Date.now() + offset.current))
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState('')
  const dirty = useRef(initial.dirty)
  const latest = useRef(answers)
  const finishing = useRef(false)
  const saving = useRef(false)
  const guard = useIntegrityGuard(token, !submitting)

  useEffect(() => { latest.current = answers }, [answers])

  const save = useCallback(async () => {
    if (!dirty.current || saving.current || finishing.current) return
    saving.current = true
    dirty.current = false
    setSaveState({ kind: 'saving', text: 'Saving…' })
    try {
      await rpc('screening_save', { p_token: token, p_answers: latest.current, p_final: false })
      setSaveState({ kind: 'idle', text: `Saved ${new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })}` })
    } catch (e) {
      if (e.code?.startsWith('SCREENING_') || e.code === 'SESSION_INVALID') { finishing.current = true; onReload(); return }
      dirty.current = true
      setSaveState({ kind: 'offline', text: 'Not saved — retrying…' })
    } finally { saving.current = false }
  }, [token, onReload])

  const submit = useCallback(async (auto) => {
    if (finishing.current) return
    if (!auto && !window.confirm('Submit your response now? You cannot edit it afterwards.')) return
    finishing.current = true
    setSubmitting(true); setError('')
    await guard.flush()
    try {
      const d = await rpc('screening_save', { p_token: token, p_answers: latest.current, p_final: true })
      store.del(draftKey)
      if (document.fullscreenElement) document.exitFullscreen().catch(() => {})
      onState(d)
    } catch (e) {
      if (e.code?.startsWith('SCREENING_') || e.code === 'SESSION_INVALID') { if (e.code !== 'SESSION_INVALID') store.del(draftKey); onReload(); return }
      setSubmitting(false)
      setError(`${e.message} Your answers are kept on this device — press Submit again.`)
      // the clock retries an automatic submit by itself; give the network a moment first
      setTimeout(() => { finishing.current = false }, auto ? 3000 : 0)
    }
  }, [token, draftKey, onState, onReload, guard])

  // autosave every 3 seconds while there are unsaved changes
  useEffect(() => {
    const t = setInterval(save, 3000)
    return () => clearInterval(t)
  }, [save])

  // the clock; at 0:00 submit whatever is on screen (the server accepts it within a short grace)
  useEffect(() => {
    const t = setInterval(() => {
      const ms = new Date(data.team.deadline) - (Date.now() + offset.current)
      setLeft(ms)
      if (ms <= 0) submit(true)
    }, 250)
    return () => clearInterval(t)
  }, [data.team.deadline, offset, submit])

  useEffect(() => {
    const warn = e => { if (dirty.current) { e.preventDefault(); e.returnValue = '' } }
    window.addEventListener('beforeunload', warn)
    return () => window.removeEventListener('beforeunload', warn)
  }, [])

  function change(i, v) {
    if (v.length - (answers[i] || '').length > BULK_INSERT_CHARS) guard.recordBulk()
    const next = answers.map((a, j) => (j === i ? v : a))
    setAnswers(next)
    dirty.current = true
    setSaveState(s => (s.kind === 'offline' ? s : { kind: 'pending', text: 'Unsaved changes' }))
    store.set(draftKey, { answers: next, at: Date.now() })
  }

  const c = data.case
  const timerCls = left <= 60_000 ? 'crit' : left <= 180_000 ? 'warn' : ''

  return (
    <div className="sc-writing sc-protected">
      {guard.notice && <div className="toast" role="alert">{guard.notice}</div>}
      {guard.needsFullscreen && (
        <div className="overlay sc-fs-cover">
          <div className="card">
            <h2>Return to fullscreen</h2>
            <p>The sprint runs in fullscreen. Your answers are saved and the timer is still running
              — <b>{fmtClock(left)}</b> left.</p>
            <p className="small muted">Leaving fullscreen is recorded and shown to the organisers.</p>
            <button className="lg" onClick={enterFullscreen}>Go back to fullscreen</button>
          </div>
        </div>
      )}
      <header className="exam-top sc-top">
        <span className="title">{data.config.event_title}</span>
        <span className="badge in_progress">{data.team.track_label}</span>
        <span className="small muted sc-team">{data.team.team_name}</span>
        <span className="spacer" />
        <span className={`save-state ${saveState.kind === 'offline' ? 'offline' : ''}`}>{saveState.text}</span>
        <span className={`timer ${timerCls}`} title="Time left">{fmtClock(left)}</span>
        <button onClick={() => submit(false)} disabled={submitting}>{submitting ? 'Submitting…' : 'Submit'}</button>
      </header>

      <div className="sc-body">
        <aside className="sc-case card">
          <div className="brand-mark">{data.config.case_title}</div>
          <h2>The case</h2>
          <dl className="sc-facts">
            {(c.facts || []).map(f => <div key={f.label}><dt>{f.label}</dt><dd>{f.text}</dd></div>)}
          </dl>
          <h3>Your role</h3>
          <p>{c.role_brief}</p>
        </aside>

        <main className="sc-answers">
          {error && <div className="error">{error}</div>}
          {(c.prompts || []).map((p, i) => (
            <section key={i} className="card sc-prompt">
              <div className="q-head"><span className="q-num">{i + 1}.</span><h3 style={{ margin: 0 }}>{p.title}</h3></div>
              <p className="muted">{p.body}</p>
              <textarea value={answers[i]} onChange={e => change(i, e.target.value)} maxLength={8000}
                        rows={9} placeholder="Type your answer…" disabled={submitting}
                        autoComplete="off" spellCheck
                        data-gramm="false" data-gramm_editor="false" data-enable-grammarly="false"
                        data-lt-active="false" />
              <div className="small muted sc-count">{words(answers[i])} words</div>
            </section>
          ))}
          <div className="row" style={{ justifyContent: 'flex-end' }}>
            <button className="lg" onClick={() => submit(false)} disabled={submitting}>
              {submitting ? 'Submitting…' : 'Submit response'}
            </button>
          </div>
        </main>
      </div>
    </div>
  )
}

function Done({ data, onSignOut }) {
  const t = data.team
  const c = data.case
  return (
    <div className="card">
      <div className="brand-mark">Response received</div>
      <h1>Thank you, {t.team_name}</h1>
      {t.submit_reason === 'TIME_UP'
        ? <div className="status-box wait">Time ran out, so your response was submitted automatically with everything saved up to that point.</div>
        : <div className="status-box ok">Your response has been submitted.</div>}
      <dl className="details">
        <dt>Track</dt><dd>{t.track_label}</dd>
        <dt>Submitted</dt><dd>{new Date(t.submitted_at).toLocaleString()}</dd>
        <dt>Team leader</dt><dd>{t.leader_name}</dd>
        <dt>Email</dt><dd>{data.email}</dd>
      </dl>
      <p className="muted small">Results will be shared by the organisers. You can close this page.</p>
      {c && (
        <details>
          <summary className="small" style={{ cursor: 'pointer' }}>View your response</summary>
          {(c.prompts || []).map((p, i) => (
            <div key={i} className="ans">
              <b>{i + 1}. {p.title}</b>
              <div className="sc-readonly">{c.answers?.[i] || <span className="muted">(no answer)</span>}</div>
            </div>
          ))}
        </details>
      )}
      <SignedInAs data={data} onSignOut={onSignOut} />
    </div>
  )
}
