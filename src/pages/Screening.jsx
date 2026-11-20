import { useCallback, useEffect, useRef, useState } from 'react'
import { rpc, store } from '../lib/api'
import { firebaseConfigured, signInWithGoogle, firebaseSignOut } from '../lib/firebase'

/**
 * PRIMUS 2026 screening round.
 *
 *   sign in (team leader's Google account)
 *     → team name + one track (Product / Consulting / Finance)
 *     → Start: the case and the track's three prompts appear, server-side timer runs
 *     → answers autosave; Submit, or the clock closes it at 0:00
 *
 * Every rule (one team per email, unique team names, the track lock after Start,
 * the deadline) is enforced by the database; this page only shows the state it returns.
 */
export default function Screening() {
  const [data, setData] = useState(null)        // screening_state() payload
  const [phase, setPhase] = useState('loading') // loading | signin | app
  const [editing, setEditing] = useState(false) // changing team name / track before Start
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const offset = useRef(0)

  const accept = useCallback(d => {
    offset.current = new Date(d.server_now) - Date.now()
    setData(d); setPhase('app'); setError('')
  }, [])

  const load = useCallback(async () => {
    try { accept(await rpc('screening_state')) }
    catch (e) {
      if (e.code === 'NOT_SIGNED_IN' || e.code === 'EMAIL_NOT_VERIFIED') { setPhase('signin'); setData(null) }
      else { setError(e.message); setPhase(p => (p === 'loading' ? 'signin' : p)) }
    }
  }, [accept])

  useEffect(() => {
    if (!firebaseConfigured) { setPhase('signin'); return }
    load()
  }, [load])

  async function google() {
    setError(''); setBusy(true)
    try { await signInWithGoogle(); await load() }
    catch (err) {
      await firebaseSignOut()
      const m = err?.message || ''
      setError(m.includes('popup-closed') || m.includes('cancelled') ? '' : (m || 'Google sign-in failed.'))
    } finally { setBusy(false) }
  }

  async function signOut() {
    await firebaseSignOut()
    setData(null); setEditing(false); setPhase('signin')
  }

  const team = data?.team
  const cfg = data?.config

  if (phase === 'loading') return <div className="center-page"><p className="muted">Loading…</p></div>

  if (phase === 'signin') return (
    <ScreeningShell>
      <div className="card">
        <div className="brand-mark">PRIMUS 2026</div>
        <h1>Screening round</h1>
        <p className="muted">Team leaders only. Sign in with the Google account you want this team’s
          response linked to — one response per team.</p>
        {firebaseConfigured ? (
          <button type="button" onClick={google} disabled={busy} className="sc-google">
            {busy ? 'Signing in…' : 'Continue with Google'}
          </button>
        ) : <div className="error">Google sign-in isn’t set up on this site yet.</div>}
        {error && <div className="error">{error}</div>}
      </div>
    </ScreeningShell>
  )

  if (team?.status === 'writing') return (
    <Writing data={data} offset={offset} onState={accept} onReload={load} />
  )

  if (team?.status === 'submitted') return (
    <ScreeningShell cfg={cfg}>
      <Done data={data} onSignOut={signOut} />
    </ScreeningShell>
  )

  // not registered yet, or registered and waiting to start
  return (
    <ScreeningShell cfg={cfg}>
      {!team || editing
        ? <RegisterForm data={data} onSaved={d => { accept(d); setEditing(false) }}
                        onCancel={team ? () => setEditing(false) : null} onSignOut={signOut} />
        : <ReadyCard data={data} onEdit={() => setEditing(true)} onStarted={accept} onSignOut={signOut} />}
      {error && <div className="error">{error}</div>}
    </ScreeningShell>
  )
}

/** Rules on the left, the action on the right — same layout as the quiz sign-in pages. */
function ScreeningShell({ cfg, children }) {
  const mins = cfg?.duration_minutes ?? 15
  return (
    <div className="split-page">
      <section className="split-left card">
        <div className="brand-mark">{cfg?.event_title || 'PRIMUS 2026 · Screening Round'}</div>
        <h1>{cfg?.case_title || 'Case File 07: The Ghost Customer'}</h1>
        <p className="muted">A {mins}-minute written case sprint. Read this before you start.</p>
        <ul className="rules">
          <li><b>Only the team leader signs in</b>, with a Google account. Each account can submit
            {' '}<b>one response for one team</b>.</li>
          <li>Enter your <b>team name</b> and choose <b>one track</b>:
            <ul className="sub-rules">
              <li><b>Product</b> — product &amp; commercial offering strategy</li>
              <li><b>Consulting</b> — strategy, operations &amp; crisis governance</li>
              <li><b>Finance</b> — corporate finance &amp; valuation</li>
            </ul>
            You can change both until you press Start. After that the track is locked.</li>
          <li>Every track works on the same case. The case file and your track’s
            {' '}<b>three prompts</b> appear only when you press <b>Start</b>.</li>
          <li><b>Your {mins}-minute timer starts the moment you press Start</b> and does not pause —
            closing or refreshing the page does not stop it.</li>
          <li>Answers <b>save automatically</b> every few seconds. When the timer reaches 0:00 your
            response is submitted with whatever has been saved.</li>
          <li>Answer all three prompts. Bullet points are fine.</li>
          <li>Use a laptop, and keep the response open in <b>one tab only</b>.</li>
        </ul>
      </section>
      <aside className="split-right">{children}</aside>
    </div>
  )
}

function SignedInAs({ data, onSignOut }) {
  return (
    <p className="small muted" style={{ marginTop: 14 }}>
      Signed in as <b>{data.email}</b>.{' '}
      <button type="button" className="ghost sm" onClick={onSignOut}>Use a different account</button>
    </p>
  )
}

function RegisterForm({ data, onSaved, onCancel, onSignOut }) {
  const [name, setName] = useState(data.team?.team_name || '')
  const [track, setTrack] = useState(data.team?.track || '')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const closed = !data.config.is_open

  async function submit(e) {
    e.preventDefault()
    if (!track) { setError('Choose a track.'); return }
    setError(''); setBusy(true)
    try { onSaved(await rpc('screening_register', { p_team_name: name, p_track: track })) }
    catch (err) { setError(err.message) }
    finally { setBusy(false) }
  }

  return (
    <form className="card" onSubmit={submit}>
      <div className="brand-mark">Step 1 of 2</div>
      <h1>{data.team ? 'Edit your team' : 'Register your team'}</h1>
      {closed && <div className="error">Registration for the screening round is closed.</div>}

      <label htmlFor="team">Team name</label>
      <input id="team" value={name} onChange={e => setName(e.target.value)} maxLength={60}
             placeholder="e.g. The Analysts" autoFocus required disabled={closed} />

      <label>Track</label>
      <div className="sc-tracks" role="radiogroup">
        {(data.tracks || []).map(t => (
          <label key={t.id} className={`sc-track ${track === t.id ? 'selected' : ''}`}>
            <input type="radio" name="track" value={t.id} checked={track === t.id}
                   onChange={() => setTrack(t.id)} disabled={closed} />
            <span><b>{t.label}</b><span className="small muted">{t.subtitle}</span></span>
          </label>
        ))}
      </div>

      {error && <div className="error">{error}</div>}
      <div className="row" style={{ marginTop: 16 }}>
        <button className="lg" style={{ flex: 1 }} disabled={busy || closed}>
          {busy ? 'Saving…' : data.team ? 'Save changes' : 'Register team'}
        </button>
        {onCancel && <button type="button" className="ghost lg" onClick={onCancel}>Cancel</button>}
      </div>
      <SignedInAs data={data} onSignOut={onSignOut} />
    </form>
  )
}

function ReadyCard({ data, onEdit, onStarted, onSignOut }) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const t = data.team
  const mins = data.config.duration_minutes

  async function start() {
    if (!window.confirm(`Start now? Your ${mins}-minute timer begins immediately and cannot be paused. Your track (${t.track_label}) will be locked.`)) return
    setBusy(true); setError('')
    try { onStarted(await rpc('screening_start')) }
    catch (err) { setError(err.message) }
    finally { setBusy(false) }
  }

  return (
    <div className="card">
      <div className="brand-mark">Step 2 of 2</div>
      <h1>Ready when you are</h1>
      <dl className="details">
        <dt>Team</dt><dd>{t.team_name}</dd>
        <dt>Track</dt><dd>{t.track_label}</dd>
        <dt>Team leader</dt><dd>{t.leader_name || data.google_name || data.email}</dd>
        <dt>Time</dt><dd>{mins} minutes, 3 prompts</dd>
      </dl>
      {data.config.is_open
        ? <div className="status-box ok">You’re registered. Press Start when your team is together and ready.</div>
        : <div className="status-box wait">The screening round is not open right now. This page will let you start once the organisers open it — refresh to check.</div>}
      {error && <div className="error">{error}</div>}
      <button className="lg" style={{ width: '100%', marginTop: 14 }} onClick={start}
              disabled={busy || !data.config.is_open}>
        {busy ? 'Starting…' : `Start the ${mins}-minute sprint`}
      </button>
      <button type="button" className="ghost" style={{ width: '100%', marginTop: 8 }} onClick={onEdit}>
        Change team name or track
      </button>
      <SignedInAs data={data} onSignOut={onSignOut} />
    </div>
  )
}

const words = s => (s.trim() ? s.trim().split(/\s+/).length : 0)
const fmtClock = ms => {
  const s = Math.max(0, Math.ceil(ms / 1000))
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}

function Writing({ data, offset, onState, onReload }) {
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

  useEffect(() => { latest.current = answers }, [answers])

  const save = useCallback(async () => {
    if (!dirty.current || saving.current || finishing.current) return
    saving.current = true
    dirty.current = false
    setSaveState({ kind: 'saving', text: 'Saving…' })
    try {
      await rpc('screening_save', { p_answers: latest.current, p_final: false })
      setSaveState({ kind: 'idle', text: `Saved ${new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })}` })
    } catch (e) {
      if (e.code?.startsWith('SCREENING_')) { finishing.current = true; onReload(); return }
      dirty.current = true
      setSaveState({ kind: 'offline', text: 'Not saved — retrying…' })
    } finally { saving.current = false }
  }, [onReload])

  const submit = useCallback(async (auto) => {
    if (finishing.current) return
    if (!auto && !window.confirm('Submit your response now? You cannot edit it afterwards.')) return
    finishing.current = true
    setSubmitting(true); setError('')
    try {
      const d = await rpc('screening_save', { p_answers: latest.current, p_final: true })
      store.del(draftKey)
      onState(d)
    } catch (e) {
      if (e.code?.startsWith('SCREENING_')) { store.del(draftKey); onReload(); return }
      setSubmitting(false)
      setError(`${e.message} Your answers are kept on this device — press Submit again.`)
      // the clock retries an automatic submit by itself; give the network a moment first
      setTimeout(() => { finishing.current = false }, auto ? 3000 : 0)
    }
  }, [draftKey, onState, onReload])

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
    const next = answers.map((a, j) => (j === i ? v : a))
    setAnswers(next)
    dirty.current = true
    setSaveState(s => (s.kind === 'offline' ? s : { kind: 'pending', text: 'Unsaved changes' }))
    store.set(draftKey, { answers: next, at: Date.now() })
  }

  const c = data.case
  const timerCls = left <= 60_000 ? 'crit' : left <= 180_000 ? 'warn' : ''

  return (
    <div className="sc-writing">
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
                        rows={9} placeholder="Type your answer…" disabled={submitting} />
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
        <dt>Team leader</dt><dd>{data.email}</dd>
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
