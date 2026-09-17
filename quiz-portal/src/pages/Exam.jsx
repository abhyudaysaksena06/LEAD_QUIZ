import { useCallback, useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { rpc, store } from '../lib/api'
import useProctor, { enterFullscreen, releaseScreen } from '../lib/useProctor'
import { requestMic, releaseMic } from '../lib/mic'
import { requestCamera, releaseCamera, cameraStream, cameraLive, captureFrame } from '../lib/camera'
import { analyse, classify, loadDetector, detectorReady, detectorError } from '../lib/vision'
import { deviceId } from '../lib/device'
import CodeWorkspace from '../components/CodeWorkspace'
import ChatBox from '../components/ChatBox'
import ConsentForm, { CONSENT_VERSION } from '../components/ConsentForm'
import { SplitPage } from '../components/Instructions'

const LETTERS = 'ABCDEFGHIJ'
const entryPath = () => (store.get('entry') === 'main' ? '/recruitment' : '/')
const fmtClock = ms => {
  const s = Math.max(0, Math.ceil(ms / 1000))
  return `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`
}
const END_TEXT = {
  MANUAL: 'You submitted your test.',
  TIME_UP: 'Time is up — your answers were submitted automatically.',
  ADMIN: 'A proctor submitted your test.',
  FLAG_LIMIT: 'Your test was submitted automatically after repeated screen violations.',
}

function Watermark({ roll }) {
  const svg = `<svg xmlns='http://www.w3.org/2000/svg' width='340' height='190'><text x='20' y='110' transform='rotate(-24 170 95)' font-family='monospace' font-size='17' fill='#000'>${roll} · LEAD Quiz</text></svg>`
  return <div className="watermark" style={{ backgroundImage: `url("data:image/svg+xml;utf8,${encodeURIComponent(svg)}")` }} />
}

function StudentChat({ token, open, onClose }) {
  const load = useCallback(() => rpc('student_get_messages', { p_token: token }), [token])
  const send = useCallback(body => rpc('student_send_message', { p_token: token, p_body: body }), [token])
  if (!open) return null
  return (
    <div className="chat-panel">
      <div className="chat-head">
        <b>Message a proctor</b><span className="spacer" />
        <button className="ghost sm" onClick={onClose} aria-label="Close chat">✕</button>
      </div>
      <ChatBox me="student" load={load} send={send} placeholder="Describe your problem…" />
    </div>
  )
}

// Round times are announced in IST, so format them in IST no matter what the
// student's device clock is set to.
const IST = 'Asia/Kolkata'
const HELPLINE = '9166220353'
function roundWhen(iso) {
  if (!iso) return null
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return null
  const date = d.toLocaleDateString('en-GB', { timeZone: IST, day: '2-digit', month: '2-digit', year: 'numeric' })
  const time = d.toLocaleTimeString('en-US', { timeZone: IST, hour: 'numeric', minute: '2-digit', hour12: true })
  return { date, time }
}

export default function Exam() {
  const nav = useNavigate()
  // Captured once. The terminated screen deletes the stored session, and that must not
  // flip `token` to undefined — which would bounce the student straight to the login page.
  const [token] = useState(() => store.get('student')?.token)

  const [phase, setPhase] = useState('loading') // loading|instructions|exam|submitted|blocked|terminated|error
  const [exam, setExam] = useState(null)        // last get_exam_state payload
  const [answers, setAnswers] = useState({})
  const [current, setCurrent] = useState(0)
  const [flagCount, setFlagCount] = useState(0)
  const [deadline, setDeadline] = useState(null)
  const [offset, setOffset] = useState(0)       // serverTime - clientTime
  const [now, setNow] = useState(Date.now())
  const [saveState, setSaveState] = useState('saved')
  const [unread, setUnread] = useState(0)
  const [chatOpen, setChatOpen] = useState(false)
  const [armed, setArmed] = useState(false)
  const [mic, setMic] = useState(false)
  const [cam, setCam] = useState(false)
  const [visionReady, setVisionReady] = useState(false)
  const [watched, setWatched] = useState(false)   // a proctor has this student open in live view
  const videoRef = useRef(null)
  const lastSent = useRef({})
  const streak = useRef({ kind: null, n: 0 })
  const [confirmSubmit, setConfirmSubmit] = useState(false)
  const [showConsent, setShowConsent] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [toast, setToast] = useState('')

  const attemptId = useRef(null)
  const pending = useRef({})        // qid -> latest unsent change
  const flushing = useRef(false)
  const flushAgain = useRef(false)
  const revisions = useRef({})
  const codeTimers = useRef({})
  const ending = useRef(false)
  const toastTimer = useRef(null)
  const warned = useRef({})

  const notice = useCallback(msg => {
    setToast(msg)
    clearTimeout(toastTimer.current)
    toastTimer.current = setTimeout(() => setToast(''), 3500)
  }, [])

  const goLogin = useCallback(() => {
    ending.current = true
    const home = entryPath()
    store.del('student'); releaseScreen(); releaseMic(); releaseCamera()
    nav(home, { replace: true })
  }, [nav])

  const handleError = useCallback(err => {
    if (err.code === 'SESSION_INVALID' || err.code === 'SESSION_TAKEN') {
      if (err.code === 'SESSION_TAKEN') { try { window.alert(err.message) } catch { /* ignore */ } }
      goLogin(); return true
    }
    return false
  }, [goLogin])

  const persistPending = () => { if (attemptId.current) store.set(`pending:${attemptId.current}`, pending.current) }

  // ---------- state loading ----------
  const applyState = useCallback(s => {
    setExam(s)
    setOffset(new Date(s.server_now).getTime() - Date.now())
    const a = s.attempt
    if (!a) { setPhase('instructions'); return }
    attemptId.current = a.id
    setFlagCount(a.flag_count)
    setDeadline(new Date(a.deadline_at).getTime())
    if (a.status === 'in_progress') {
      const loaded = {}
      for (const [qid, v] of Object.entries(s.answers || {})) {
        loaded[qid] = v
        revisions.current[qid] = Math.max(revisions.current[qid] || 0, v.revision || 0)
      }
      // unsent local work (e.g. saved offline before a crash) wins over the server copy
      const p = store.get(`pending:${a.id}`) || {}
      for (const [qid, item] of Object.entries(p)) loaded[qid] = { ...loaded[qid], ...item.local }
      pending.current = p
      setAnswers(loaded)
      ending.current = false
      setPhase('exam')
    } else {
      // frozen by a proctor: drop fullscreen so nothing counts as a violation while paused
      if (a.status === 'paused') { setArmed(false); releaseScreen() }
      setPhase(a.status)
    }
  }, [])

  const load = useCallback(async () => {
    try { applyState(await rpc('get_exam_state', { p_token: token })) }
    catch (e) { if (!handleError(e)) { setError(e.message); setPhase('error') } }
  }, [token, applyState, handleError])

  useEffect(() => {
    if (!token) { nav(entryPath(), { replace: true }); return }
    load()
  }, [token, nav, load])

  // ---------- saving (queue + retry; survives offline and reloads) ----------
  const flush = useCallback(async () => {
    if (flushing.current) { flushAgain.current = true; return }
    flushing.current = true
    try {
      do {
        flushAgain.current = false
        for (const [qid, item] of Object.entries(pending.current)) {
          setSaveState('saving')
          const r = item.kind === 'mcq'
            ? await rpc('save_mcq_answer', { p_token: token, p_question_id: Number(qid),
                                             p_selected_index: item.local.selected_index })
            : await rpc('save_code_answer', { p_token: token, p_question_id: Number(qid),
                                              p_code: item.local.code, p_language: item.local.language,
                                              p_revision: item.revision })
          if (r && r.ok === false) { pending.current = {}; persistPending(); ending.current = true; releaseScreen(); await load(); return }
          if (pending.current[qid] === item) delete pending.current[qid]
          persistPending()
        }
      } while (flushAgain.current)
      setSaveState('saved')
    } catch (e) {
      if (!handleError(e)) setSaveState('offline')
    } finally {
      flushing.current = false
    }
  }, [token, load, handleError])

  const queue = useCallback((qid, item) => {
    pending.current[qid] = item
    persistPending()
    flush()
  }, [flush])

  function selectOption(q, index) {
    setAnswers(a => ({ ...a, [q.id]: { ...a[q.id], selected_index: index } }))
    queue(q.id, { kind: 'mcq', local: { selected_index: index } })
  }

  function changeCode(q, code, language) {
    setAnswers(a => ({ ...a, [q.id]: { ...a[q.id], code, language } }))
    setSaveState('saving')
    clearTimeout(codeTimers.current[q.id])
    codeTimers.current[q.id] = setTimeout(() => {
      const rev = (revisions.current[q.id] || 0) + 1
      revisions.current[q.id] = rev
      queue(q.id, { kind: 'coding', revision: rev, local: { code, language } })
    }, 800)
  }

  // ---------- screen control ----------
  const onFlag = useCallback(async (kind, detail) => {
    if (ending.current) return
    try {
      const r = await rpc('report_flag', { p_token: token, p_kind: kind, p_detail: detail || null })
      if (r.flag_count != null) setFlagCount(r.flag_count)
      if (r.status === 'blocked') {
        // Their paper is submitted, but we keep them signed in so the locked screen
        // (with the proctor chat on it) is right there — no signing in again.
        ending.current = true
        setArmed(false); releaseScreen(); releaseMic(); releaseCamera()
        setMic(false); setCam(false)
        await load()
      } else if (r.counted) {
        notice(`Warning: violation ${r.flag_count} of ${r.max_flags} recorded.`)
      }
    } catch (e) {
      if (!ending.current) handleError(e)
    }
  }, [token, notice, handleError])

  const { isFullscreen, isFocused, shield } = useProctor({
    active: phase === 'exam' && armed, onFlag, onNotice: notice,
  })

  // Mic: permission only, nothing recorded (src/lib/mic.js).
  // Camera: analysed on this machine; a snapshot is sent only when something needs a proctor.
  async function ensureMedia() {
    if (exam?.config?.require_mic) {
      try { await requestMic(); setMic(true) }
      catch {
        setMic(false)
        setError('Microphone access is required for this test. Allow it in your browser and try again.')
        return false
      }
    }
    if (exam?.config?.require_camera) {
      try {
        await requestCamera(); setCam(true)
        // load in the background; failure is reported to proctors, never silent
        loadDetector().then(() => setVisionReady(true)).catch(() => setVisionReady(false))
      }
      catch {
        setCam(false)
        setError('Camera access is required for this test. Allow it in your browser and try again.')
        return false
      }
    }
    return true
  }

  // Consent is required once, and recorded server-side, before anyone can start.
  async function agreeToConsent() {
    setBusy(true); setError('')
    try {
      await rpc('student_accept_consent', { p_token: token, p_version: CONSENT_VERSION })
      setShowConsent(false)
      setBusy(false)
      await start(true)
    } catch (e) {
      if (!handleError(e)) setError(e.message)
      setBusy(false)
    }
  }

  async function start(consentGiven = false) {
    if (!consentGiven && !exam?.student?.consented) { setShowConsent(true); return }
    setBusy(true); setError('')
    if (!(await ensureMedia())) { setBusy(false); return }
    try { await enterFullscreen() }
    catch { setError('Fullscreen is required. Allow it and try again.'); setBusy(false); return }
    try {
      applyState(await rpc('start_attempt', { p_token: token }))
      setArmed(true)
    } catch (e) {
      if (!handleError(e)) setError(e.message)
      releaseScreen()
    }
    setBusy(false)
  }

  async function resume() {
    if (!(await ensureMedia())) return
    try { await enterFullscreen(); setArmed(true) }
    catch { notice('Fullscreen is required to continue.') }
  }

  async function submit() {
    if (ending.current) return
    ending.current = true
    setBusy(true); setConfirmSubmit(false)
    Object.values(codeTimers.current).forEach(clearTimeout)
    try {
      await flush()
      await rpc('submit_attempt', { p_token: token })
    } catch (e) {
      if (handleError(e)) return
    }
    setArmed(false); releaseScreen(); releaseMic(); releaseCamera(); setMic(false); setCam(false)
    store.del(`pending:${attemptId.current}`)
    await load()
    setBusy(false)
  }

  async function signOut() {
    try { await rpc('student_logout', { p_token: token }) } catch { /* already gone */ }
    goLogin()
  }

  // ---------- heartbeat: timer sync, admin actions, unread chat, retry saves ----------
  useEffect(() => {
    if (!['exam', 'blocked', 'paused'].includes(phase)) return
    const tick = async () => {
      try {
        const needCam = Boolean(exam?.config?.require_camera)
        const camOk = needCam ? (cameraLive() && detectorReady()) : null
        const camNote = !needCam ? null
          : !cameraLive() ? 'camera off or blocked'
          : !detectorReady() ? (detectorError() ? 'detector failed to load' : 'detector still loading')
          : null
        const h = await rpc('student_heartbeat', {
          p_token: token, p_device: deviceId(), p_camera_ok: camOk, p_camera_note: camNote,
        })
        setOffset(new Date(h.server_now).getTime() - Date.now())
        setUnread(h.unread)
        setWatched(Boolean(h.watch))
        if (h.deadline_at) setDeadline(new Date(h.deadline_at).getTime())
        if (h.flag_count != null) setFlagCount(h.flag_count)
        if (phase === 'exam') {
          if (h.status !== 'in_progress') { ending.current = true; setArmed(false); releaseScreen(); load() }
          else if (Object.keys(pending.current).length) flush()
        }
        // restored / resumed by a proctor
        if ((phase === 'blocked' || phase === 'paused') && h.status === 'in_progress') { setArmed(false); load() }
      } catch (e) {
        if (!handleError(e) && Object.keys(pending.current).length) setSaveState('offline')
      }
    }
    // a random offset so hundreds of students who start together don't all call in the same second
    let t
    const first = setTimeout(() => { tick(); t = setInterval(tick, 10000) }, Math.random() * 3000)
    return () => { clearTimeout(first); clearInterval(t) }
  }, [phase, token, load, flush, handleError])

  // ---------- countdown ----------
  useEffect(() => {
    if (phase !== 'exam' && phase !== 'instructions') return
    const t = setInterval(() => setNow(Date.now()), phase === 'exam' ? 500 : 1000)
    return () => clearInterval(t)
  }, [phase])

  // keep the on-screen preview fed by the live camera
  useEffect(() => {
    const v = videoRef.current
    const s = cameraStream()
    if (v && s && v.srcObject !== s) { v.srcObject = s; v.play().catch(() => {}) }
  }, [cam, phase])

  // Camera watch. Runs entirely on this machine; a snapshot is uploaded only when the
  // same thing is seen twice in a row, and at most once a minute per kind. Nothing here
  // flags the student — a proctor decides (see admin_decide_detection).
  useEffect(() => {
    if (phase !== 'exam' || !armed || !cam) return
    let stopped = false
    let running = false          // never let two inferences overlap - that is what janks the UI
    const run = async () => {
      if (stopped || running || document.hidden) return
      const v = videoRef.current
      if (!v || !v.videoWidth) return
      running = true
      try {
        const res = await analyse(v, { detectPhone: exam?.config?.detect_phone !== false })
        if (!visionReady && detectorReady()) setVisionReady(true)
        const kind = classify(res)
        // seen twice running before a proctor is bothered
        if (kind && streak.current.kind === kind) streak.current.n += 1
        else streak.current = { kind, n: 1 }
        if (!kind || streak.current.n < 2) return
        if (Date.now() - (lastSent.current[kind] || 0) < 60000) return
        lastSent.current[kind] = Date.now()
        const shot = captureFrame(v)
        await rpc('student_report_detection', {
          p_token: token, p_kind: kind, p_detail: res.detail,
          p_image_b64: shot?.b64 ?? null, p_mime: shot?.mime ?? 'image/webp',
        })
      } catch { /* monitoring must never interrupt the exam */ }
      finally { running = false }
    }
    run()
    const t = setInterval(run, 2500)
    return () => { stopped = true; clearInterval(t) }
  }, [phase, armed, cam, token, visionReady, exam?.config?.detect_phone])

  // Live view. Sends a small still about once a second, and ONLY while a proctor has this
  // student open. Nothing is stored: each frame overwrites the last, and stops when they stop.
  useEffect(() => {
    if (phase !== 'exam' || !cam || !watched) return
    let stopped = false
    let sending = false
    const send = async () => {
      if (stopped || sending) return
      const v = videoRef.current
      const shot = v && v.videoWidth ? captureFrame(v, { maxDim: 320, quality: 0.5 }) : null
      if (!shot) return
      sending = true
      try {
        const r = await rpc('student_live_frame', { p_token: token, p_mime: shot.mime, p_b64: shot.b64 })
        if (r && r.watching === false) { stopped = true; setWatched(false) }
      } catch { /* the live view must never interrupt the exam */ }
      finally { sending = false }
    }
    send()
    const t = setInterval(send, 1000)
    return () => { stopped = true; clearInterval(t) }
  }, [phase, cam, watched, token])

  // while waiting for a proctor to open the batch, poll so Start unlocks by itself
  useEffect(() => {
    if (phase !== 'instructions' || exam?.can_start) return
    const t = setInterval(load, 10000)
    return () => clearInterval(t)
  }, [phase, exam?.can_start, load])

  const remaining = deadline ? deadline - (now + offset) : null
  const timeUp = phase === 'exam' && remaining != null && remaining <= 0

  useEffect(() => {
    if (phase !== 'exam' || remaining == null) return
    if (remaining <= 5 * 60000 && remaining > 60000 && !warned.current.five) { warned.current.five = true; notice('5 minutes left.') }
    if (remaining <= 60000 && remaining > 0 && !warned.current.one) { warned.current.one = true; notice('1 minute left — your answers are saved.') }
  }, [phase, remaining, notice])

  useEffect(() => { if (timeUp) submit() }) // eslint-disable-line react-hooks/exhaustive-deps

  // ---------- render ----------
  const roll = exam?.student?.roll_no || ''
  const cfg = exam?.config
  const questions = exam?.questions || []
  const q = questions[current]
  const isAnswered = x => x.kind === 'mcq'
    ? answers[x.id]?.selected_index != null
    : (answers[x.id]?.code ?? '').trim().length > 0 && (answers[x.id]?.code ?? '') !== (x.starter_code ?? '')
  const answeredCount = questions.filter(isAnswered).length
  const chat = (
    <>
      <StudentChat token={token} open={chatOpen} onClose={() => setChatOpen(false)} />
      <button className="chat-fab" onClick={() => { setChatOpen(o => !o); setUnread(0) }}>
        💬 Help{unread > 0 && <span className="dot">{unread}</span>}
      </button>
    </>
  )

  if (phase === 'loading') return <div className="center-page"><p className="muted">Loading…</p></div>

  if (phase === 'error') return (
    <div className="center-page"><div className="card narrow">
      <h1>Something went wrong</h1><div className="error">{error}</div>
      <div className="row"><button onClick={load}>Try again</button><button className="ghost" onClick={goLogin}>Sign out</button></div>
    </div></div>
  )

  if (phase === 'instructions') {
    const who = store.get('student') || {}
    const when = exam?.batch ? roundWhen(exam.batch.starts_at) : null
    const startsIn = exam?.batch?.starts_at ? new Date(exam.batch.starts_at) - (now + offset) : null
    const approval = exam?.open_quiz_approval
    const pending = approval === 'pending'
    const rejected = approval === 'rejected'
    const waiting = !exam?.batch
      ? 'You have not been assigned to a round yet. Please contact a proctor.'
      : !cfg?.exam_open
        ? 'The exam is not open yet. Wait for the proctor’s signal.'
        : `${exam.batch.name} has not been started yet. This page unlocks by itself when a proctor starts your round — keep it open.`
    return (
    <>
    <SplitPage cfg={cfg} minutes={exam?.batch?.duration_minutes ?? cfg?.duration_minutes}>
      <div className="card">
        <div className="brand-mark">{cfg?.exam_title}</div>
        <h2>Your details</h2>
        <dl className="details">
          <dt>Name</dt><dd>{exam?.student?.full_name || who.full_name || '—'}</dd>
          <dt>Roll number</dt><dd className="mono">{roll || '—'}</dd>
          {who.email && <><dt>Email</dt><dd className="mono small">{who.email}</dd></>}
          <dt>Round</dt><dd>{pending || rejected ? 'Open Quiz' : (exam?.batch?.name || '—')}</dd>
          {approval && approval !== 'not_needed' && (
            <><dt>Approval</dt><dd style={{ color: pending ? 'var(--warn)' : rejected ? 'var(--bad)' : 'var(--ok)' }}>
              {pending ? 'Pending' : rejected ? 'Not approved' : 'Approved'}</dd></>
          )}
          {when && <><dt>Scheduled</dt><dd>{when.date} · <b>{when.time}</b> <span className="muted">IST</span></dd></>}
        </dl>

        {pending ? (
          <div className="status-box wait">
            <div className="countdown"><b>Signed in — pending admin approval</b></div>
            Your Thapar account is registered. An admin needs to approve it before you can start the quiz.
            This page updates by itself as soon as you are approved — keep it open.
          </div>
        ) : rejected ? (
          <div className="error">
            Your registration for the open quiz was not approved. If you think this is a mistake, contact the
            LEAD team on <b>9166220353</b>.
          </div>
        ) : exam?.can_start
          ? <div className="status-box ok">Your round is open. Read the instructions, then start when you are ready.</div>
          : (
            <div className="status-box wait">
              {startsIn != null && startsIn > 0 && cfg?.exam_open && (
                <div className="countdown">Starts in <b className="mono">{fmtClock(startsIn)}</b></div>
              )}
              {waiting}
            </div>
          )}
        {error && <div className="error">{error}</div>}

        <button className="lg" style={{ width: '100%', marginTop: 12 }}
                onClick={() => start()} disabled={busy || !exam?.can_start}>
          {busy ? 'Starting…' : exam?.can_start ? 'Start test in fullscreen'
            : pending ? 'Start (waiting for approval)' : 'Start (waiting for your round)'}
        </button>
        <div className="row" style={{ marginTop: 10 }}>
          {!exam?.can_start && <button className="ghost sm" onClick={load}>Refresh</button>}
          <span className="spacer" />
          <button className="ghost sm" onClick={signOut}>Sign out</button>
        </div>
      </div>
    </SplitPage>
      {showConsent && (
        <ConsentForm
          examTitle={cfg?.exam_title} roll={roll} name={exam?.student?.full_name}
          requireCamera={cfg?.require_camera} requireMic={cfg?.require_mic}
          maxFlags={cfg?.max_flags} minutes={exam?.batch?.duration_minutes ?? cfg?.duration_minutes}
          busy={busy} onAgree={agreeToConsent} onCancel={() => setShowConsent(false)}
        />
      )}
      {chat}
    </>
    )
  }


  if (phase === 'submitted') return (
    <div className="center-page"><div className="card narrow" style={{ textAlign: 'center' }}>
      <div className="brand-mark">{cfg?.exam_title}</div>
      <h1>Test submitted ✓</h1>
      <p>{END_TEXT[exam?.attempt?.submit_reason] || END_TEXT.MANUAL}</p>
      <p className="muted small">Roll number {roll}. Results will be shared by the organisers.</p>
      <button onClick={signOut}>Sign out</button>
    </div></div>
  )

  if (phase === 'terminated') return (
    <div className="center-page"><div className="card narrow" style={{ borderTop: '4px solid var(--bad)' }}>
      <h1>Test submitted automatically</h1>
      <p>You reached <b>{flagCount}</b> screen violations, so your test was submitted and you were signed out.</p>
      <p>Your answers were saved and will be graded.</p>
      <p className="muted">If this happened by mistake, sign in again and use the chat to contact a proctor.
        If chat does not resolve it, call <b><a href={`tel:+91${HELPLINE}`}>{HELPLINE}</a></b>.</p>
      <button onClick={goLogin}>Sign in again</button>
    </div></div>
  )

  if (phase === 'paused') return (
    <div className="center-page">
      <div className="card wide" style={{ borderTop: '4px solid var(--warn)' }}>
        <h1>Your test is paused</h1>
        <p>A proctor has paused your test. <b>Your timer is frozen</b> — you’ll get back exactly the
          time you had left, and your answers are saved.</p>
        <p className="muted">This page continues by itself as soon as they resume you. Use the chat below if you need to reach them.</p>
        <div style={{ display: 'grid', gridTemplateRows: '240px auto', border: '1px solid var(--line)', borderRadius: 8, marginTop: 10 }}>
          <ChatBox me="student" load={() => rpc('student_get_messages', { p_token: token })}
                   send={body => rpc('student_send_message', { p_token: token, p_body: body })} />
        </div>
      </div>
    </div>
  )

  if (phase === 'banned') return (
    <div className="center-page">
      <div className="card narrow" style={{ borderTop: '4px solid var(--bad)' }}>
        <h1>Test ended</h1>
        <p>Your access to this test has been withdrawn by the exam office.</p>
        <p className="muted small">Roll number {roll}. Please speak to a proctor in person.</p>
        <button onClick={goLogin}>Back to sign in</button>
      </div>
    </div>
  )

  if (phase === 'blocked') return (
    <div className="center-page">
      <div className="card wide" style={{ borderTop: '4px solid var(--bad)' }}>
        <h1>Your test is locked</h1>
        <p>{END_TEXT.FLAG_LIMIT} Your answers were saved.</p>
        <p className="muted">You are still signed in. If you believe this was a mistake, message a proctor below —
          if they restore your test, this page continues by itself with the time you had left.</p>
        <p className="small">If this is urgent and chat does not resolve it, call <b>
          <a href={`tel:+91${HELPLINE}`}>{HELPLINE}</a></b>.</p>
        <div style={{ display: 'grid', gridTemplateRows: '260px auto', border: '1px solid var(--line)', borderRadius: 8, marginTop: 10 }}>
          <ChatBox me="student" load={() => rpc('student_get_messages', { p_token: token })}
                   send={body => rpc('student_send_message', { p_token: token, p_body: body })} />
        </div>
        <div className="row" style={{ marginTop: 12 }}><span className="spacer" /><button className="ghost" onClick={signOut}>Sign out</button></div>
      </div>
    </div>
  )

  // ---------- phase === 'exam' ----------
  const hot = flagCount > 0
  const showOverlay = !armed || !isFullscreen
  const timerClass = remaining != null && remaining <= 60000 ? 'crit' : remaining != null && remaining <= 3 * 60000 ? 'warn' : ''

  return (
    <div className="exam">
      <Watermark roll={roll} />
      <header className="exam-top">
        <span className="title">{cfg?.exam_title}</span>
        <span className="muted small">{roll}</span>
        <span className="spacer" />
        <span className={`save-state ${saveState === 'offline' ? 'offline' : ''}`}>
          {saveState === 'saved' ? '✓ All answers saved' : saveState === 'saving' ? 'Saving…' : '⚠ Offline — answers will sync when reconnected'}
        </span>
        {cam && (
          <video ref={videoRef} muted playsInline autoPlay title="Your camera is being monitored"
                 style={{ width: 56, height: 42, borderRadius: 4, objectFit: 'cover',
                          background: '#000', border: '1px solid var(--line)' }} />
        )}
        {cam && (
          <span className={`flags ${visionReady ? '' : 'hot'}`}
                title={visionReady ? 'Camera monitoring active' : 'Camera monitoring is still starting'}>
            {visionReady ? 'Camera on' : 'Camera starting…'}
          </span>
        )}
        {mic && <span className="flags" title="Microphone permission granted">🎙 Mic on</span>}
        <span className={`flags ${hot ? 'hot' : ''}`}>Violations {flagCount}/{cfg?.max_flags}</span>
        <span className={`timer ${timerClass}`} aria-label="Time remaining">{remaining == null ? '--:--' : fmtClock(remaining)}</span>
        <button onClick={() => setConfirmSubmit(true)} disabled={busy}>Submit</button>
      </header>

      <div className="exam-body" style={showOverlay || !isFocused ? { filter: 'blur(12px)' } : undefined}>
        <aside className="palette">
          <h3>Multiple choice</h3>
          <div className="palette-grid">
            {questions.map((x, i) => x.kind === 'mcq' && (
              <button key={x.id} className={`${isAnswered(x) ? 'answered' : ''} ${i === current ? 'current' : ''}`}
                      onClick={() => setCurrent(i)}>{i + 1}</button>
            ))}
          </div>
          <h3>Coding</h3>
          <div className="palette-grid">
            {questions.map((x, i) => x.kind === 'coding' && (
              <button key={x.id} className={`${isAnswered(x) ? 'answered' : ''} ${i === current ? 'current' : ''}`}
                      onClick={() => setCurrent(i)}>{i + 1}</button>
            ))}
          </div>
          <div className="legend">
            <span><i style={{ background: 'var(--ok-soft)' }} />Answered ({answeredCount}/{questions.length})</span>
            <span><i />Not answered</span>
          </div>
        </aside>

        <main className="question-pane">
          {q && (
            <>
              <div className="q-head">
                <span className="q-num">Question {current + 1} of {questions.length}</span>
                <span className="badge">{q.kind === 'mcq' ? 'Multiple choice' : 'Coding'}</span>
                {q.kind === 'coding' && <span className="badge" style={{ background: 'var(--warn-soft)', color: 'var(--warn)' }}>Optional</span>}
                <span className="muted small">{q.marks} mark{Number(q.marks) === 1 ? '' : 's'}</span>
              </div>
              {q.title && <h2>{q.title}</h2>}
              <div className="q-body">{q.body}</div>

              {q.kind === 'mcq' ? (
                <div className="options">
                  {q.options.map((o, k) => (
                    <button key={o.i} className={`option ${answers[q.id]?.selected_index === o.i ? 'selected' : ''}`}
                            onClick={() => selectOption(q, o.i)}>
                      <span className="letter">{LETTERS[k]}</span><span>{o.t}</span>
                    </button>
                  ))}
                </div>
              ) : (
                <CodeWorkspace
                  key={q.id}
                  code={answers[q.id]?.code ?? q.starter_code ?? ''}
                  language={answers[q.id]?.language || q.language || 'python'}
                  tests={q.tests || []}
                  onCodeChange={code => changeCode(q, code, answers[q.id]?.language || q.language || 'python')}
                  onLanguageChange={lang => changeCode(q, answers[q.id]?.code ?? q.starter_code ?? '', lang)}
                  onBlockedPaste={() => { notice('Pasting from outside the editor is disabled.'); onFlag('PASTE_BLOCKED') }}
                />
              )}

              <div className="q-nav">
                <button className="ghost" disabled={current === 0} onClick={() => setCurrent(c => c - 1)}>← Previous</button>
                {current < questions.length - 1
                  ? <button onClick={() => setCurrent(c => c + 1)}>Next →</button>
                  : <button className="success" onClick={() => setConfirmSubmit(true)}>Finish &amp; submit</button>}
              </div>
            </>
          )}
        </main>
      </div>

      {showOverlay && (
        <div className="overlay"><div className={`card ${armed ? 'alert' : ''}`}>
          <h2>{armed ? 'You left fullscreen' : 'Continue your test'}</h2>
          <p>{armed
            ? <>This has been recorded. Violations: <b>{flagCount} of {cfg?.max_flags}</b>. At {cfg?.max_flags} your test is submitted automatically.</>
            : 'Your test is in progress and your timer is running. Return to fullscreen to continue.'}</p>
          <button className="lg" onClick={resume}>Return to fullscreen</button>
        </div></div>
      )}

      {confirmSubmit && (
        <div className="overlay"><div className="card">
          <h2>Submit your test?</h2>
          <p>
            Multiple choice answered: <b>{questions.filter(x => x.kind === 'mcq' && isAnswered(x)).length} of {questions.filter(x => x.kind === 'mcq').length}</b>.
            {questions.some(x => x.kind === 'coding') && <>
              <br />Coding attempted: <b>{questions.filter(x => x.kind === 'coding' && isAnswered(x)).length} of {questions.filter(x => x.kind === 'coding').length}</b> <span className="muted">(optional)</span>.
            </>}
          </p>
          <p>You can’t change answers after submitting.</p>
          <div className="row" style={{ justifyContent: 'center' }}>
            <button className="ghost" onClick={() => setConfirmSubmit(false)}>Keep working</button>
            <button className="success" onClick={submit} disabled={busy}>Submit now</button>
          </div>
        </div></div>
      )}

      {shield && <div className="shield" />}
      {toast && <div className="toast">{toast}</div>}
      {chat}
    </div>
  )
}
