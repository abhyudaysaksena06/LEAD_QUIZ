import { useCallback, useEffect, useMemo, useState } from 'react'
import { rpc } from '../../lib/api'
import { fmtTime } from './util'

const STATUS = {
  registered: { label: 'Registered', colour: 'var(--ok)' },
  signed_in: { label: 'Signed in, not registered', colour: 'var(--warn)' },
  not_eligible: { label: 'Not eligible', colour: 'var(--bad)' },
  recruitment_student: { label: 'Recruitment student', colour: 'var(--muted)' },
}
const ATTEMPT = { in_progress: 'Writing', paused: 'Paused', submitted: 'Submitted', blocked: 'Blocked', banned: 'Banned' }

/** Everyone who has tried the open quiz: who signed in, who registered, their phone and email. */
export default function OpenQuiz({ token, onOpen }) {
  const [data, setData] = useState(null)
  const [err, setErr] = useState('')
  const [filter, setFilter] = useState('all')
  const [q, setQ] = useState('')
  const [busy, setBusy] = useState(false)

  async function decide(emails, approve) {
    if (!emails.length) return
    if (!approve && !window.confirm(`Reject ${emails.length === 1 ? emails[0] : emails.length + ' students'}? They will not be able to start.`)) return
    setBusy(true)
    try { await rpc('admin_open_quiz_approve', { p_token: token, p_emails: emails, p_approve: approve }); await load() }
    catch (e) { setErr(e.message) }
    finally { setBusy(false) }
  }

  const load = useCallback(async () => {
    try { setData(await rpc('admin_open_quiz_students', { p_token: token })); setErr('') }
    catch (e) { setErr(e.message) }
  }, [token])

  useEffect(() => {
    load()
    const t = setInterval(() => { if (!document.hidden) load() }, 15000)
    return () => clearInterval(t)
  }, [load])

  const all = useMemo(() => data?.students || [], [data])
  const sum = data?.summary || {}
  const rows = useMemo(() => {
    const t = q.trim().toLowerCase()
    return all.filter(s => {
      if (filter === 'pending') { if (s.approval !== 'pending') return false }
      else if (filter === 'rejected') { if (s.approval !== 'rejected') return false }
      else if (filter === 'started' ? !s.attempt_status : filter !== 'all' && s.status !== filter) return false
      if (!t) return true
      return [s.email, s.full_name, s.google_name, s.roll_no, s.phone].some(v => (v || '').toLowerCase().includes(t))
    })
  }, [all, filter, q])

  function exportCsv() {
    const cols = ['email', 'full_name', 'google_name', 'roll_no', 'phone', 'status', 'approval', 'approved_by', 'attempt_status', 'score',
                  'first_signed_in_at', 'registered_at', 'last_signed_in_at', 'sign_in_count', 'submitted_at']
    const esc = v => `"${String(v ?? '').replace(/"/g, '""')}"`
    const csv = [cols.join(','), ...rows.map(s => cols.map(c => esc(s[c])).join(','))].join('\n')
    const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv' }))
    const a = document.createElement('a')
    a.href = url; a.download = `open-quiz-students-${new Date().toISOString().slice(0, 10)}.csv`; a.click()
    setTimeout(() => URL.revokeObjectURL(url), 1000)
  }

  return (
    <>
      <div className="stats">
        <div className="stat"><b style={{ color: sum.pending ? 'var(--warn)' : undefined }}>{sum.pending ?? '—'}</b><span>Awaiting approval</span></div>
        <div className="stat"><b style={{ color: 'var(--ok)' }}>{sum.registered ?? '—'}</b><span>Registered</span></div>
        <div className="stat"><b style={{ color: 'var(--warn)' }}>{sum.signed_in ?? '—'}</b><span>Signed in, not registered</span></div>
        <div className="stat"><b>{sum.started ?? '—'}</b><span>Started the quiz</span></div>
        <div className="stat"><b>{sum.submitted ?? '—'}</b><span>Finished</span></div>
      </div>

      <div className="toolbar">
        <input placeholder="Search name, email, roll number or phone" value={q}
               onChange={e => setQ(e.target.value)} style={{ minWidth: 260 }} />
        <select value={filter} onChange={e => setFilter(e.target.value)}>
          <option value="all">Everyone ({all.length})</option>
          <option value="pending">Awaiting approval ({sum.pending ?? 0})</option>
          <option value="rejected">Rejected</option>
          <option value="registered">Registered</option>
          <option value="signed_in">Signed in, not registered</option>
          <option value="started">Started the quiz</option>
          <option value="recruitment_student">Recruitment students</option>
        </select>
        <button className="ghost sm" onClick={load}>Refresh</button>
        <button className="ghost sm" onClick={exportCsv} disabled={!rows.length}>Export CSV</button>
        {rows.some(s => s.approval === 'pending') && (
          <button className="sm" disabled={busy}
                  onClick={() => decide(rows.filter(s => s.approval === 'pending').map(s => s.email), true)}>
            Approve all {rows.filter(s => s.approval === 'pending').length} shown
          </button>
        )}
        <span className="small muted">{rows.length} shown · updates every 15 seconds</span>
      </div>
      {err && <div className="error">{err}</div>}

      <div className="table-wrap">
        <table>
          <thead><tr>
            <th>Name</th><th>Email</th><th>Phone</th><th>Roll no</th><th>Status</th><th>Quiz</th>
            <th>First signed in</th><th></th>
          </tr></thead>
          <tbody>
            {!data && <tr><td colSpan={8} className="muted">Loading…</td></tr>}
            {data && rows.length === 0 && <tr><td colSpan={8} className="muted">Nobody here yet.</td></tr>}
            {rows.map(s => {
              const st = STATUS[s.status] || { label: s.status, colour: 'var(--muted)' }
              return (
                <tr key={s.email}>
                  <td>{s.full_name || s.google_name || <span className="muted">—</span>}
                    {s.full_name && s.google_name && s.full_name !== s.google_name &&
                      <div className="small muted">Google: {s.google_name}</div>}
                  </td>
                  <td className="mono small">{s.email}</td>
                  <td className="mono small">{s.phone ? <a href={`tel:+91${s.phone}`}>{s.phone}</a> : <span className="muted">—</span>}</td>
                  <td className="mono small">{s.roll_no || <span className="muted">—</span>}</td>
                  <td><span className="badge" style={{ color: st.colour }}>{st.label}</span>
                    {s.approval === 'pending' && <div className="small" style={{ color: 'var(--warn)', fontWeight: 600 }}>Awaiting approval</div>}
                    {s.approval === 'approved' && <div className="small" style={{ color: 'var(--ok)' }}>Approved{s.approved_by ? ` by ${s.approved_by}` : ''}</div>}
                    {s.approval === 'rejected' && <div className="small" style={{ color: 'var(--bad)' }}>Rejected{s.approved_by ? ` by ${s.approved_by}` : ''}</div>}
                    {s.sign_in_count > 1 && <div className="small muted">{s.sign_in_count} sign-ins</div>}
                  </td>
                  <td className="small">{s.attempt_status
                    ? <>{ATTEMPT[s.attempt_status] || s.attempt_status}{s.score != null && ['submitted', 'blocked'].includes(s.attempt_status) && ` · ${s.score}`}</>
                    : <span className="muted">not started</span>}</td>
                  <td className="small">{fmtTime(s.first_signed_in_at)}</td>
                  <td style={{ whiteSpace: 'nowrap' }}>
                    {(s.approval === 'pending' || s.approval === 'rejected') && (
                      <button className="sm" disabled={busy} onClick={() => decide([s.email], true)}>Approve</button>
                    )}
                    {(s.approval === 'pending' || s.approval === 'approved') && !s.attempt_status && (
                      <button className="sm ghost" style={{ marginLeft: 4 }} disabled={busy} onClick={() => decide([s.email], false)}>Reject</button>
                    )}
                    {s.roll_no && <button className="sm ghost" style={{ marginLeft: 4 }} onClick={() => onOpen(s.roll_no)}>Open ›</button>}
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
