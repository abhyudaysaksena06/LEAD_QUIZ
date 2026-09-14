import { useCallback, useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { rpc, store } from '../lib/api'
import useProctor, { enterFullscreen, releaseScreen } from '../lib/useProctor'
import { requestMic, releaseMic } from '../lib/mic'
import { requestCamera, releaseCamera, cameraStream, captureFrame } from '../lib/camera'
import { analyse, classify, loadDetector } from '../lib/vision'
import { deviceId } from '../lib/device'
import CodeWorkspace from '../components/CodeWorkspace'
import ChatBox from '../components/ChatBox'

const LETTERS = 'ABCDEFGHIJ'
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
  const videoRef = useRef(null)
  const lastSent = useRef({})
  const streak = useRef({ kind: null, n: 0 })
  const [confirmSubmit, setConfirmSubmit] = useState(false)
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
    store.del('student'); releaseScreen(); releaseMic(); releaseCamera()
    nav('/', { replace: true })
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
    if (!token) { nav('/', { replace: true }); return }
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
        ending.current = true
        releaseScreen(); releaseMic(); releaseCamera(); store.del('student')
        setPhase('terminated')
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
      try { await requestCamera(); setCam(true); loadDetector().catch(() => {}) }
      catch {
        setCam(false)
        setError('Camera access is required for this test. Allow it in your browser and try again.')
        return false
      }
    }
    return true
  }

  async function start() {
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
        const h = await rpc('student_heartbeat', { p_token: token, p_device: deviceId() })
        setOffset(new Date(h.server_now).getTime() - Date.now())
        setUnread(h.unread)
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
    const t = setInterval(tick, 10000)
    tick()
    return () => clearInterval(t)
  }, [phase, token, load, flush, handleError])

  // ---------- countdown ----------
  useEffect(() => {
    if (phase !== 'exam') return
    const t = setInterval(() => setNow(Date.now()), 500)
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
    const run = async () => {
      if (stopped || document.hidden) return
      const v = videoRef.current
      if (!v || !v.videoWidth) return
      try {
        const res = await analyse(v)
        const kind = classify(res)
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
    }
    const t = setInterval(run, 8000)
    return () => { stopped = true; clearInterval(t) }
  }, [phase, armed, cam, token])

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

  if (phase === 'instructions') return (
    <div className="center-page">
      <div className="card wide">
        <div className="brand-mark">{cfg?.exam_title}</div>
        <h1>Before you begin</h1>
        <p>
          Signed in as <b>{roll}</b>{exam?.student?.full_name ? ` · ${exam.student.full_name}` : ''}
          {exam?.batch && <span className="badge" style={{ marginLeft: 8 }}>{exam.batch.name}</span>}
        </p>
        <ul className="rules">
          <li><b>{cfg?.mcq_count + cfg?.coding_count} questions</b>: {cfg?.mcq_count} multiple choice
            {cfg?.coding_count > 0 && <> and {cfg?.coding_count} coding (<b>optional</b> — attempt them if you have time)</>}.</li>
          <li><b>Your own {exam?.batch?.duration_minutes ?? cfg?.duration_minutes}-minute timer</b> starts when you press Start. It does not pause.</li>
          <li>The test runs in <b>fullscreen</b>. Leaving fullscreen, switching tabs or opening another application is recorded as a violation.</li>
          <li><b>{cfg?.max_flags} violations</b> and your test is submitted automatically and you are signed out.</li>
          <li>Holding <b>Esc</b> exits fullscreen — that counts as a violation.</li>
          {cfg?.require_camera && <li><b>Your camera must stay on</b> and is monitored during the test. Keep your face visible, sit alone, and keep your phone out of sight.</li>}
          {cfg?.require_mic && <li><b>Microphone access is required</b> for the duration of the test. Your browser will ask for permission when you press Start.</li>}
          <li>Answers save automatically. Don’t refresh or close the browser.</li>
          <li>Problem during the test? Use the <b>💬 Help</b> button to message a proctor.</li>
        </ul>
        {!exam?.can_start && (
          <div className="error">
            {!exam?.batch
              ? 'You have not been assigned to a batch yet. Please contact a proctor.'
              : !cfg?.exam_open
                ? 'The exam is not open yet. Wait for the proctor’s signal.'
                : `${exam.batch.name} has not been started yet. This page will unlock automatically when a proctor starts your batch.`}
          </div>
        )}
        {error && <div className="error">{error}</div>}
        <div className="row">
          <button className="lg" onClick={start} disabled={busy || !exam?.can_start}>{busy ? 'Starting…' : 'Start test in fullscreen'}</button>
          {!exam?.can_start && <button className="ghost" onClick={load}>Refresh</button>}
          <span className="spacer" />
          <button className="ghost" onClick={signOut}>Sign out</button>
        </div>
      </div>
      {chat}
    </div>
  )

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
      <p className="muted">If this happened by mistake, sign in again and use the chat to contact a proctor.</p>
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
        <p className="muted">If you believe this was a mistake, message a proctor below. If they restore your test, this page updates automatically and you can continue with your remaining time.</p>
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
