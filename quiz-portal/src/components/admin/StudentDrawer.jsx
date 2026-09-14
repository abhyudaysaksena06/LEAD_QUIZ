import { useCallback, useEffect, useState } from 'react'
import { rpc } from '../../lib/api'
import ChatBox from '../ChatBox'
import { fmtLeft, fmtTime, REASON_LABEL, StatusBadge } from './util'
import { IdViewer } from './Registrations'

const LETTERS = 'ABCDEFGHIJ'

export default function StudentDrawer({ token, roll, offset, onClose, onChanged }) {
  const [d, setD] = useState(null)
  const [err, setErr] = useState('')
  const [busy, setBusy] = useState(false)
  const [reason, setReason] = useState('')
  const [extra, setExtra] = useState(0)
  const [resetTo, setResetTo] = useState(2)
  const [marks, setMarks] = useState({})
  const [showId, setShowId] = useState(false)
  const [, tick] = useState(0)

  const load = useCallback(async () => {
    try { setD(await rpc('admin_student_detail', { p_token: token, p_roll: roll })); setErr('') }
    catch (e) { setErr(e.message) }
  }, [token, roll])

  useEffect(() => {
    load()
    const t = setInterval(load, 8000)
    const c = setInterval(() => tick(x => x + 1), 1000)
    const esc = e => { if (e.key === 'Escape') onClose() }
    window.addEventListener('keydown', esc)
    return () => { clearInterval(t); clearInterval(c); window.removeEventListener('keydown', esc) }
  }, [load, onClose])

  const loadChat = useCallback(() => rpc('admin_get_messages', { p_token: token, p_roll: roll }), [token, roll])
  const sendChat = useCallback(body => rpc('admin_send_message', { p_token: token, p_roll: roll, p_body: body }), [token, roll])

  async function act(fn, args = {}, confirmText) {
    if (confirmText && !window.confirm(confirmText)) return false
    setBusy(true); setErr('')
    try {
      await rpc(fn, { p_token: token, p_roll: roll, ...args })
      await load(); onChanged()
      return true
    } catch (e) { setErr(e.message); return false }
    finally { setBusy(false) }
  }

  async function unblock(e) {
    e.preventDefault()
    if (!reason.trim()) { setErr('Enter a reason — it is saved to the audit log.'); return }
    const ok = await act('admin_unblock', {
      p_extra_minutes: Number(extra) || 0, p_reset_flags_to: Number(resetTo), p_reason: reason.trim(),
    })
    if (ok) setReason('')
  }

  const a = d?.attempt
  const status = a?.status || 'not_started'
  const left = a && a.status === 'in_progress' ? new Date(a.deadline_at) - (Date.now() + offset) : null
  const counted = (d?.flags || []).filter(f => f.counted)

  return (
    <>
      <div className="drawer-bg" onClick={onClose} />
      <aside className="drawer" role="dialog" aria-label={`Student ${roll}`}>
        <div className="drawer-head">
          <div>
            <b style={{ fontSize: 17 }}>{roll}</b>
            <span className="muted" style={{ marginLeft: 8 }}>{d?.student?.full_name}</span>
          </div>
          <StatusBadge status={status} />
          <span className="spacer" />
          <button className="ghost sm" onClick={() => setShowId(true)}>Photo ID</button>
          <button className="ghost" onClick={onClose}>Close ✕</button>
        </div>

        <div className="drawer-body">
          <div>
            {err && <div className="error">{err}</div>}

            <div className="section">
              <h3>Summary</h3>
              {!a ? <p className="muted">Has not started the test.</p> : (
                <dl className="kv">
                  <dt>Status</dt><dd><StatusBadge status={status} /> {a.submit_reason && <span className="muted small">· {REASON_LABEL[a.submit_reason]}</span>}</dd>
                  <dt>Violations</dt><dd><b style={{ color: a.flag_count ? 'var(--bad)' : undefined }}>{a.flag_count}</b></dd>
                  <dt>Started</dt><dd>{fmtTime(a.started_at)}</dd>
                  <dt>Time left</dt><dd>{a.status === 'in_progress' ? fmtLeft(left) : '—'}</dd>
                  <dt>Submitted</dt><dd>{fmtTime(a.submitted_at)}</dd>
                  <dt>Score</dt><dd>{a.total_score ?? '—'} <span className="muted small">(MCQ {a.mcq_score ?? '—'} · coding {a.coding_score ?? '—'})</span></dd>
                  <dt>Times unblocked</dt><dd>{a.unblock_count}</dd>
                </dl>
              )}
            </div>

            {status === 'blocked' && (
              <form className="section" style={{ borderColor: 'var(--bad)' }} onSubmit={unblock}>
                <h3>Unblock {roll}</h3>
                <p className="small muted">
                  The time the student had left when blocked is restored automatically. They must sign in again.
                </p>
                {counted.length > 0 && (
                  <ul className="small" style={{ margin: '0 0 8px', paddingLeft: 18 }}>
                    {counted.map((f, i) => <li key={i}>{fmtTime(f.created_at)} — {f.kind.replace(/_/g, ' ').toLowerCase()}</li>)}
                  </ul>
                )}
                <label>Reason (required)</label>
                <input value={reason} onChange={e => setReason(e.target.value)} placeholder="e.g. Windows update popup stole focus" />
                <div className="row">
                  <div style={{ flex: 1 }}>
                    <label>Extra minutes</label>
                    <input type="number" min="0" max="60" value={extra} onChange={e => setExtra(e.target.value)} />
                  </div>
                  <div style={{ flex: 1 }}>
                    <label>Reset violations to</label>
                    <select value={resetTo} onChange={e => setResetTo(e.target.value)}>
                      <option value={0}>0 (clean slate)</option>
                      <option value={1}>1</option>
                      <option value={2}>2 (one strike left)</option>
                    </select>
                  </div>
                </div>
                <button className="success" style={{ marginTop: 12 }} disabled={busy}>Unblock &amp; restore</button>
              </form>
            )}

            {a && (
              <div className="section">
                <h3>Actions</h3>
                <div className="row wrap">
                  {status === 'in_progress' && <>
                    <button className="sm" disabled={busy} onClick={() => act('admin_extend_time', { p_minutes: 5 })}>+5 min</button>
                    <button className="sm" disabled={busy} onClick={() => act('admin_extend_time', { p_minutes: 10 })}>+10 min</button>
                    <button className="sm ghost" disabled={busy}
                            onClick={() => act('admin_pause_attempt', {},
                              `Pause ${roll}'s test? Their timer stops and they get the time back when you resume.`)}>
                      ⏸ Pause
                    </button>
                    <button className="sm danger" disabled={busy}
                            onClick={() => act('admin_force_submit', {}, `Force-submit ${roll}'s test now?`)}>Force submit</button>
                  </>}
                  {status === 'paused' && (
                    <button className="sm success" disabled={busy} onClick={() => act('admin_resume_attempt', {})}>
                      ▶ Resume ({fmtLeft(new Date(a.deadline_at) - new Date(a.paused_at))} left)
                    </button>
                  )}
                  <button className="sm ghost" disabled={busy}
                          onClick={() => act('admin_reset_attempt', {},
                            `Reset ${roll}? This DELETES their answers and lets them start again with a new random paper.`)}>
                    Reset attempt
                  </button>
                </div>
              </div>
            )}

            <div className="section" style={{ borderColor: d?.student?.banned ? 'var(--bad)' : undefined }}>
              <h3>Access</h3>
              {d?.student?.banned ? (
                <>
                  <p className="small">
                    <b style={{ color: 'var(--bad)' }}>Banned</b> — they cannot sign in by password or Google.
                    {d.student.banned_reason && <> Reason: {d.student.banned_reason}</>}
                  </p>
                  <button className="sm" disabled={busy}
                          onClick={() => act('admin_unban_student', {}, `Lift the ban on ${roll}?`)}>
                    Lift ban
                  </button>
                  <span className="small muted" style={{ marginLeft: 8 }}>
                    Use <b>Reset attempt</b> afterwards if they should sit the test again.
                  </span>
                </>
              ) : (
                <>
                  <p className="small muted">
                    Banning ends any live attempt, signs them out and blocks every future sign-in.
                    Their answers are kept.
                  </p>
                  <button className="sm danger" disabled={busy}
                          onClick={() => {
                            const why = window.prompt(`Ban ${roll}? Give a reason (saved to the audit log):`)
                            if (why && why.trim()) act('admin_ban_student', { p_reason: why.trim() })
                          }}>
                    Ban student
                  </button>
                </>
              )}
            </div>

            {(d?.flags?.length || 0) > 0 && (
              <div className="section">
                <h3>Activity log</h3>
                <table>
                  <thead><tr><th>Time</th><th>Event</th><th>Counted</th></tr></thead>
                  <tbody>
                    {d.flags.map((f, i) => (
                      <tr key={i}>
                        <td className="mono">{fmtTime(f.created_at)}</td>
                        <td>{f.kind.replace(/_/g, ' ').toLowerCase()}</td>
                        <td>{f.counted ? <b style={{ color: 'var(--bad)' }}>yes</b> : <span className="muted">no</span>}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}

            {a && (
              <div className="section">
                <h3>Answers</h3>
                {d.questions.map((q, i) => (
                  <div className="ans" key={q.id}>
                    <div className="row">
                      <b>Q{i + 1}</b><span className="badge">{q.kind}</span>
                      <span className="small muted">{q.title}</span>
                      <span className="spacer" />
                      {q.kind === 'mcq' && (q.selected_index == null
                        ? <span className="small muted">unanswered</span>
                        : q.selected_index === q.correct_index
                          ? <span className="small" style={{ color: 'var(--ok)', fontWeight: 600 }}>✓ correct</span>
                          : <span className="small" style={{ color: 'var(--bad)', fontWeight: 600 }}>✗ wrong</span>)}
                    </div>
                    {q.kind === 'mcq' ? (
                      <div className="row wrap" style={{ marginTop: 4 }}>
                        {(q.options || []).map((o, k) => (
                          <span key={k} className={`opt ${k === q.correct_index ? 'correct' : ''} ${k === q.selected_index && k !== q.correct_index ? 'wrong' : ''}`}>
                            {LETTERS[k]}. {o}
                          </span>
                        ))}
                      </div>
                    ) : (
                      <div style={{ marginTop: 6 }}>
                        <div className="small muted">Language: {q.language || '—'}</div>
                        <pre className="code-view">{q.code || '(no code)'}</pre>
                        <div className="row" style={{ marginTop: 6 }}>
                          <span className="small">Marks</span>
                          <input type="number" min="0" max={q.marks} step="0.5" style={{ width: 90 }}
                                 value={marks[q.id] ?? q.coding_marks ?? ''}
                                 onChange={e => setMarks(m => ({ ...m, [q.id]: e.target.value }))} />
                          <span className="small muted">/ {q.marks}</span>
                          <button className="sm" disabled={busy || marks[q.id] === undefined || marks[q.id] === ''}
                                  onClick={() => act('admin_grade_coding', { p_question_id: q.id, p_marks: Number(marks[q.id]) })}>
                            Save grade
                          </button>
                        </div>
                        {q.graded_by && <div className="small muted">marked by {q.graded_by}</div>}
                      </div>
                    )}
                  </div>
                ))}
              </div>
            )}
          </div>

          <div className="section" style={{ position: 'sticky', top: 0, padding: 0, display: 'grid', gridTemplateRows: 'auto 420px auto' }}>
            <div className="chat-head"><b>Chat with {roll}</b></div>
            <ChatBox me="admin" load={loadChat} send={sendChat} pollMs={3000} />
          </div>
        </div>
      </aside>
      {showId && <IdViewer token={token} roll={roll} onClose={() => setShowId(false)} />}
    </>
  )
}
