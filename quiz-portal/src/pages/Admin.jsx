import { useCallback, useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { rpc, store } from '../lib/api'
import StudentDrawer from '../components/admin/StudentDrawer'
import Inbox from '../components/admin/Inbox'
import Batches from '../components/admin/Batches'
import Submissions from '../components/admin/Submissions'
import Registrations from '../components/admin/Registrations'
import Roster from '../components/admin/Roster'
import StudentLive from '../components/admin/StudentLive'
import CameraReview from '../components/admin/CameraReview'
import { fmtLeft, fmtTime, REASON_LABEL, StatusBadge } from '../components/admin/util'

function Dashboard({ students, batches, offset, onOpen }) {
  const [search, setSearch] = useState('')
  const [status, setStatus] = useState('all')
  const [batch, setBatch] = useState('all')
  const [roll, setRoll] = useState('')
  const [note, setNote] = useState('')

  const count = s => students.filter(x => x.status === s).length
  const q = search.trim().toLowerCase()
  const rows = students.filter(s =>
    (status === 'all' || s.status === status) &&
    (batch === 'all' || String(s.batch_id) === batch) &&
    (!q || s.roll_no.toLowerCase().includes(q) || (s.full_name || '').toLowerCase().includes(q)))

  function openByRoll(e) {
    e.preventDefault()
    const r = roll.trim()
    if (students.some(s => s.roll_no === r)) { onOpen(r); setRoll(''); setNote('') }
    else setNote(`No student with roll number ${r}.`)
  }

  function exportCsv() {
    const cols = ['roll_no', 'full_name', 'batch_name', 'status', 'submit_reason', 'flag_count', 'answered', 'total_questions',
                  'mcq_score', 'coding_score', 'total_score', 'started_at', 'submitted_at', 'unblock_count']
    const esc = v => (v == null ? '' : `"${String(v).replace(/"/g, '""')}"`)
    const csv = [cols.join(','), ...students.map(s => cols.map(c => esc(s[c])).join(','))].join('\n')
    const a = document.createElement('a')
    a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv' }))
    a.download = `lead-quiz-results-${new Date().toISOString().slice(0, 16).replace(/[:T]/g, '-')}.csv`
    a.click()
    setTimeout(() => URL.revokeObjectURL(a.href), 1000)
  }

  return (
    <>
      <div className="stats">
        <div className="stat"><b>{students.length}</b><span>Students</span></div>
        <div className="stat"><b>{count('not_started')}</b><span>Not started</span></div>
        <div className="stat"><b style={{ color: 'var(--brand)' }}>{count('in_progress')}</b><span>In progress</span></div>
        <div className="stat"><b style={{ color: 'var(--ok)' }}>{count('submitted')}</b><span>Submitted</span></div>
        <div className="stat"><b style={{ color: 'var(--bad)' }}>{count('blocked')}</b><span>Blocked</span></div>
        <div className="stat"><b>{students.reduce((n, s) => n + Number(s.unread || 0), 0)}</b><span>Unread chats</span></div>
      </div>

      <div className="toolbar">
        <form className="row" onSubmit={openByRoll}>
          <input value={roll} onChange={e => setRoll(e.target.value)} placeholder="Roll no → open / unblock" />
          <button>Open</button>
        </form>
        <input value={search} onChange={e => setSearch(e.target.value)} placeholder="Filter by roll no or name" />
        <select value={status} onChange={e => setStatus(e.target.value)}>
          <option value="all">All statuses</option>
          <option value="not_started">Not started</option>
          <option value="in_progress">In progress</option>
          <option value="submitted">Submitted</option>
          <option value="blocked">Blocked</option>
        </select>
        <select value={batch} onChange={e => setBatch(e.target.value)}>
          <option value="all">All batches</option>
          {batches.map(b => <option key={b.id} value={String(b.id)}>{b.name}{b.is_open ? ' (open)' : ''}</option>)}
        </select>
        <span className="spacer" />
        <button className="ghost" onClick={exportCsv}>Export results CSV</button>
      </div>
      {note && <div className="error">{note}</div>}

      <div className="table-wrap">
        <table>
          <thead><tr>
            <th>Roll no</th><th>Name</th><th>Batch</th><th>Status</th><th>Violations</th><th>Answered</th>
            <th>Time left / ended</th><th>Score</th><th>Chat</th><th></th>
          </tr></thead>
          <tbody>
            {rows.length === 0 && <tr><td colSpan={10} className="muted">No students match.</td></tr>}
            {rows.map(s => {
              const left = s.status === 'in_progress' ? new Date(s.deadline_at) - (Date.now() + offset) : null
              return (
                <tr key={s.roll_no}>
                  <td className="mono"><b>{s.roll_no}</b></td>
                  <td>{s.full_name || <span className="muted">—</span>}</td>
                  <td className="small">{s.batch_name || <span className="muted">—</span>}</td>
                  <td><StatusBadge status={s.status} />{s.submit_reason && <div className="small muted">{REASON_LABEL[s.submit_reason]}</div>}</td>
                  <td style={{ color: s.flag_count ? 'var(--bad)' : undefined, fontWeight: s.flag_count ? 700 : 400 }}>{s.flag_count ?? '—'}</td>
                  <td>{s.total_questions ? `${s.answered}/${s.total_questions}` : '—'}</td>
                  <td className="mono">{s.status === 'in_progress' ? fmtLeft(left) : s.submitted_at ? fmtTime(s.submitted_at) : '—'}</td>
                  <td>{s.total_score ?? '—'}</td>
                  <td>{s.unread > 0 ? <span className="unread">{s.unread}</span> : ''}</td>
                  <td style={{ whiteSpace: 'nowrap' }}>
                    {s.status === 'blocked'
                      ? <button className="sm danger" onClick={() => onOpen(s.roll_no)}>Review &amp; unblock</button>
                      : <button className="sm ghost" onClick={() => onOpen(s.roll_no)}>View</button>}
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
    </>
  )
}

function StudentsTab({ token, batches, onChanged }) {
  const [text, setText] = useState('')
  const [msg, setMsg] = useState('')
  const [busy, setBusy] = useState(false)
  const [batchId, setBatchId] = useState(String(batches[0]?.id ?? ''))

  async function save(e) {
    e.preventDefault()
    const rows = text.split('\n').map(l => l.trim()).filter(Boolean).map(l => {
      const [roll_no, password, ...name] = l.split(/[,\t]/).map(x => x.trim())
      return { roll_no, password, full_name: name.join(' ') || null }
    })
    const bad = rows.filter(r => !r.roll_no || !r.password)
    if (bad.length) { setMsg(`${bad.length} line(s) are missing a roll number or password.`); return }
    setBusy(true)
    try {
      const r = await rpc('admin_upsert_students', { p_token: token, p_rows: rows,
                                                     p_batch_id: batchId ? Number(batchId) : null })
      setMsg(`Saved ${r.count} student(s).`); setText(''); onChanged()
    } catch (err) { setMsg(err.message) }
    finally { setBusy(false) }
  }

  return (
    <form className="section" style={{ maxWidth: 760 }} onSubmit={save}>
      <h2>Add or update students</h2>
      <p className="muted small">One per line: <code>roll_no,password,full name</code> (name optional). Username is the roll number.
        An existing roll number gets its password updated.</p>
      <label>Add to batch</label>
      <select value={batchId} onChange={e => setBatchId(e.target.value)} style={{ maxWidth: 320 }}>
        {batches.map(b => <option key={b.id} value={String(b.id)}>{b.name}{b.is_open ? ' (open)' : ''}</option>)}
      </select>
      <p className="small muted">Existing students listed here are <b>moved</b> into this batch.</p>
      <textarea rows={12} value={text} onChange={e => setText(e.target.value)}
                placeholder={'ROLL_NO,PASSWORD,Full Name'}
                style={{ fontFamily: 'var(--mono)', fontSize: 13 }} />
      {msg && <p className="small" style={{ marginTop: 8 }}>{msg}</p>}
      <button style={{ marginTop: 10 }} disabled={busy || !text.trim()}>{busy ? 'Saving…' : 'Save students'}</button>
    </form>
  )
}

function QuestionsTab({ token }) {
  const [qs, setQs] = useState(null)
  const [err, setErr] = useState('')
  useEffect(() => {
    rpc('admin_list_questions', { p_token: token }).then(setQs).catch(e => setErr(e.message))
  }, [token])
  if (err) return <div className="error">{err}</div>
  if (!qs) return <p className="muted">Loading…</p>
  const mcq = qs.filter(q => q.kind === 'mcq' && q.active).length
  const cod = qs.filter(q => q.kind === 'coding' && q.active).length
  return (
    <>
      <div className="stats">
        <div className="stat"><b>{mcq}</b><span>Active MCQ</span></div>
        <div className="stat"><b>{cod}</b><span>Active coding</span></div>
      </div>
      <p className="muted small">Each student draws a random paper from this bank. Questions are loaded via SQL (see <code>supabase/</code>).</p>
      <div className="table-wrap">
        <table>
          <thead><tr><th>ID</th><th>Type</th><th>Title / question</th><th>Answer</th><th>Marks</th><th>Active</th></tr></thead>
          <tbody>
            {qs.map(q => (
              <tr key={q.id}>
                <td className="mono">{q.id}</td>
                <td><span className="badge">{q.kind}</span></td>
                <td><b>{q.title}</b><div className="small muted" style={{ maxWidth: 520, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{q.body}</div></td>
                <td className="small">{q.kind === 'mcq' ? `${'ABCDEFGHIJ'[q.correct_index]}. ${q.options?.[q.correct_index] ?? ''}` : 'manual'}</td>
                <td>{q.marks}</td>
                <td>{q.active ? 'yes' : 'no'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  )
}

function SettingsTab({ token, config, onChanged }) {
  const [open, setOpen] = useState(config.exam_open)
  const [duration, setDuration] = useState(config.duration_minutes)
  const [title, setTitle] = useState(config.exam_title)
  const [mcq, setMcq] = useState(config.mcq_count)
  const [coding, setCoding] = useState(config.coding_count)
  const [reqMic, setReqMic] = useState(config.require_mic)
  const [maxCon, setMaxCon] = useState(config.max_concurrent ?? 200)
  const [reqCam, setReqCam] = useState(config.require_camera ?? true)
  const [detectPhone, setDetectPhone] = useState(config.detect_phone ?? true)
  const [msg, setMsg] = useState('')

  async function save(e) {
    e.preventDefault()
    try {
      await rpc('admin_update_config', { p_token: token, p_exam_open: open,
                                         p_duration_minutes: Number(duration), p_exam_title: title,
                                         p_mcq_count: Number(mcq), p_coding_count: Number(coding),
                                         p_require_mic: reqMic, p_max_concurrent: Number(maxCon),
                                         p_require_camera: reqCam, p_detect_phone: detectPhone })
      setMsg('Saved.'); onChanged()
    } catch (err) { setMsg(err.message) }
  }

  return (
    <form className="section" style={{ maxWidth: 520 }} onSubmit={save}>
      <h2>Exam settings</h2>
      <label>Exam title</label>
      <input value={title} onChange={e => setTitle(e.target.value)} />
      <label>Duration per student (minutes)</label>
      <input type="number" min="1" max="600" value={duration} onChange={e => setDuration(e.target.value)} />
      <p className="small muted">Applies to students who start after saving. Use +5 / +10 min on a student for individual extensions.</p>
      <label className="row" style={{ fontWeight: 600 }}>
        <input type="checkbox" style={{ width: 'auto' }} checked={open} onChange={e => setOpen(e.target.checked)} />
        Exam open — students can press Start
      </label>
      <label>Maximum students sitting at once</label>
      <input type="number" min="1" max="2000" value={maxCon} onChange={e => setMaxCon(e.target.value)} />
      <p className="small muted">Beyond this, Start is refused with “at capacity” until someone finishes.</p>

      <label className="row" style={{ fontWeight: 600 }}>
        <input type="checkbox" style={{ width: 'auto' }} checked={reqCam} onChange={e => setReqCam(e.target.checked)} />
        Require camera (monitored for phones and extra people)
      </label>
      <p className="small muted">Detections go to <b>Camera review</b> for a proctor to approve or dismiss.
        Nothing is flagged automatically and no snapshot is kept after you decide.</p>

      <label className="row" style={{ fontWeight: 600 }}>
        <input type="checkbox" style={{ width: 'auto' }} checked={detectPhone}
               onChange={e => setDetectPhone(e.target.checked)} />
        Also look for phones (less reliable)
      </label>
      <p className="small muted">Person counting is dependable; phone detection is not — small dark objects can
        read as a phone, and a phone in someone’s lap is invisible to a laptop camera. Turn this off to send
        only “more than one person” and “nobody in frame” for review.</p>

      <label className="row" style={{ fontWeight: 600 }}>
        <input type="checkbox" style={{ width: 'auto' }} checked={reqMic} onChange={e => setReqMic(e.target.checked)} />
        Require microphone permission to start
      </label>
      <p className="small muted">Students grant permission and their browser shows the microphone indicator for the
        whole test. <b>No audio is recorded, transmitted or stored</b> — the system has no capability to do so.</p>
      <div className="row">
        <div style={{ flex: 1 }}>
          <label>MCQ per student</label>
          <input type="number" min="0" max="200" value={mcq} onChange={e => setMcq(e.target.value)} />
        </div>
        <div style={{ flex: 1 }}>
          <label>Coding per student</label>
          <input type="number" min="0" max="50" value={coding} onChange={e => setCoding(e.target.value)} />
        </div>
      </div>
      <p className="small muted">Coding questions are always optional for students. Set coding to <b>0</b> for an MCQ-only exam.
        Changes apply to students who start after saving · auto-submit at {config.max_flags} violations.</p>
      {msg && <p className="small">{msg}</p>}
      <button style={{ marginTop: 6 }}>Save settings</button>
    </form>
  )
}

export default function Admin() {
  const nav = useNavigate()
  const admin = store.get('admin')
  const token = admin?.token
  const [tab, setTab] = useState('live')
  const [data, setData] = useState(null)
  const [offset, setOffset] = useState(0)
  const [error, setError] = useState('')
  const [openRoll, setOpenRoll] = useState(null)
  const [cameraQueue, setCameraQueue] = useState(0)
  const [, tick] = useState(0)

  const logout = useCallback(async (callServer = true) => {
    if (callServer) { try { await rpc('admin_logout', { p_token: token }) } catch { /* ignore */ } }
    store.del('admin'); nav('/admin/login', { replace: true })
  }, [token, nav])

  const refresh = useCallback(async () => {
    try {
      const d = await rpc('admin_overview', { p_token: token })
      setData(d); setOffset(new Date(d.server_now) - Date.now()); setError('')
      try { setCameraQueue((await rpc('admin_review_queue', { p_token: token })).length) } catch { /* pre-upgrade db */ }
    } catch (e) {
      if (e.code === 'ADMIN_SESSION_INVALID') logout(false)
      else setError(e.message)
    }
  }, [token, logout])

  useEffect(() => {
    if (!token) { nav('/admin/login', { replace: true }); return }
    refresh()
    const t = setInterval(refresh, 5000)
    const c = setInterval(() => tick(x => x + 1), 1000)
    return () => { clearInterval(t); clearInterval(c) }
  }, [token, nav, refresh])

  const closeDrawer = useCallback(() => setOpenRoll(null), [])
  const students = data?.students || []
  const batches = data?.batches || []
  const unread = students.reduce((n, s) => n + Number(s.unread || 0), 0)
  const attention = students.filter(s => Number(s.unread || 0) > 0 || Number(s.flag_count || 0) > 0).length

  return (
    <div className="admin">
      <header className="admin-top">
        <b>LEAD Quiz · Proctor</b>
        {data && <span className={`badge ${data.config.exam_open ? 'submitted' : 'blocked'}`}>
          Exam {data.config.exam_open ? 'OPEN' : 'CLOSED'}</span>}
        <span className="spacer" />
        {data?.admins?.filter(a => a.active).length > 0 && (
          <span className="small" title="proctors signed in and active">
            {data.admins.filter(a => a.active).length} proctor(s) on duty
          </span>
        )}
        <span className="small">{admin?.display_name || admin?.username}</span>
        <button className="ghost sm" onClick={() => logout()}>Sign out</button>
      </header>

      <nav className="tabs">
        {[['live', `Student Live${attention ? ` (${attention})` : ''}`],
          ['camera', `Camera review${cameraQueue ? ` (${cameraQueue})` : ''}`], ['dashboard', 'Dashboard'],
          ['batches', 'Rounds'], ['registrations', 'Registrations'],
          ['submissions', 'Submissions'], ['chat', `Chat${unread ? ` (${unread})` : ''}`],
          ['students', 'Students'], ['questions', 'Question bank'], ['settings', 'Settings']].map(([id, label]) => (
          <button key={id} className={tab === id ? 'active' : ''} onClick={() => setTab(id)}>{label}</button>
        ))}
      </nav>

      <main className="admin-main">
        {error && <div className="error">{error}</div>}
        {!data ? <p className="muted">Loading…</p> : <>
          {tab === 'live' && <StudentLive token={token} onOpen={setOpenRoll} />}
          {tab === 'camera' && <CameraReview token={token} />}
          {tab === 'dashboard' && <Dashboard students={students} batches={batches} offset={offset} onOpen={setOpenRoll} />}
          {tab === 'batches' && <Batches token={token} batches={batches} config={data.config} onChanged={refresh} />}
          {tab === 'registrations' && <Registrations token={token} batches={batches}
                                                     registration={data.registration} onChanged={refresh} />}
          {tab === 'submissions' && <Submissions token={token} students={students} onOpen={setOpenRoll} onChanged={refresh} />}
          {tab === 'chat' && <Inbox token={token} students={students} me={data.me} admins={data.admins || []}
                                    onOpenStudent={setOpenRoll} onChanged={refresh} />}
          {tab === 'students' && <>
            <Roster token={token} onOpen={setOpenRoll} />
            <details style={{ marginTop: 18 }}>
              <summary className="small muted" style={{ cursor: 'pointer' }}>
                Add students with a roll number and password (not needed — students sign in with Google)
              </summary>
              <StudentsTab token={token} batches={batches} onChanged={refresh} />
            </details>
          </>}
          {tab === 'questions' && <QuestionsTab token={token} />}
          {tab === 'settings' && <SettingsTab token={token} config={data.config} onChanged={refresh} />}
        </>}
      </main>

      {openRoll && <StudentDrawer token={token} roll={openRoll} offset={offset}
                                  onClose={closeDrawer} onChanged={refresh} />}
    </div>
  )
}
