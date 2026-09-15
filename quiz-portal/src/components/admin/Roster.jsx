import { useCallback, useEffect, useMemo, useState } from 'react'
import { rpc } from '../../lib/api'
import { fmtTime } from './util'
import { IdViewer } from './Registrations'

// What "all formalities done" means: the student signed in with Google, claimed
// their allowlist entry (roll number), typed their full name, and uploaded a photo ID.
function Steps({ s }) {
  const items = [
    ['Signed in', s.registered],
    ['Roll no', !!s.roll_no],
    ['Name', !!s.full_name],
    ['Photo ID', s.has_id],
  ]
  return (
    <span style={{ display: 'inline-flex', gap: 4, flexWrap: 'wrap' }}>
      {items.map(([label, ok]) => (
        <span key={label} className="badge" title={label}
              style={{ background: ok ? 'var(--ok-soft, #e6f6ec)' : 'var(--line-soft, #f1f3f5)',
                       color: ok ? 'var(--ok)' : 'var(--muted, #888)' }}>
          {ok ? '✓' : '·'} {label}
        </span>
      ))}
    </span>
  )
}

export default function Roster({ token, onOpen }) {
  const [data, setData] = useState(null)
  const [err, setErr] = useState('')
  const [filter, setFilter] = useState('all')
  const [round, setRound] = useState('all')
  const [q, setQ] = useState('')
  const [viewing, setViewing] = useState(null)

  const load = useCallback(async () => {
    try { setData(await rpc('admin_roster', { p_token: token })); setErr('') }
    catch (e) { setErr(e.message) }
  }, [token])

  useEffect(() => {
    load()
    const t = setInterval(load, 15000)
    return () => clearInterval(t)
  }, [load])

  const students = data?.students || []
  const sum = data?.summary || {}
  const rounds = useMemo(
    () => [...new Set(students.map(s => s.round_name || 'Unassigned'))].sort(), [students])

  const rows = useMemo(() => students.filter(s => {
    if (round !== 'all' && (s.round_name || 'Unassigned') !== round) return false
    if (filter === 'complete' && !s.complete) return false
    if (filter === 'pending' && s.complete) return false
    if (filter === 'notsignedin' && s.registered) return false
    if (filter === 'noid' && (s.has_id || !s.registered)) return false
    const t = q.trim().toLowerCase()
    if (t && ![s.email, s.listed_name, s.full_name, s.roll_no, String(s.serial_no ?? '')]
              .some(v => (v || '').toLowerCase().includes(t))) return false
    return true
  }), [students, filter, round, q])

  function exportCsv() {
    const head = ['sheet_no', 'email', 'round', 'listed_name', 'entered_name', 'roll_no',
                  'signed_in', 'photo_id', 'all_formalities', 'attempt']
    const esc = v => `"${String(v ?? '').replace(/"/g, '""')}"`
    const csv = [head.join(',')].concat(rows.map(s => [
      s.serial_no ?? '', s.email, s.round_name || '', s.listed_name || '', s.full_name || '', s.roll_no || '',
      s.registered ? 'yes' : 'no', s.has_id ? 'yes' : 'no', s.complete ? 'yes' : 'no',
      s.attempt_status || '',
    ].map(esc).join(','))).join('\n')
    const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv' }))
    const a = document.createElement('a')
    a.href = url; a.download = 'lead-quiz-roster.csv'; a.click()
    URL.revokeObjectURL(url)
  }

  const pct = sum.total ? Math.round((sum.complete / sum.total) * 100) : 0

  return (
    <>
      <div className="stats">
        <div className="stat"><b>{sum.total ?? '—'}</b><span>On the roster</span></div>
        <div className="stat"><b>{sum.registered ?? '—'}</b><span>Signed in</span></div>
        <div className="stat"><b>{sum.with_id ?? '—'}</b><span>Photo ID uploaded</span></div>
        <div className="stat">
          <b style={{ color: 'var(--ok)' }}>{sum.complete ?? '—'}</b>
          <span>All formalities done{sum.total ? ` (${pct}%)` : ''}</span>
        </div>
        <div className="stat">
          <b style={{ color: sum.pending ? 'var(--bad)' : undefined }}>{sum.pending ?? '—'}</b>
          <span>Still pending</span>
        </div>
      </div>

      {(data?.by_round || []).length > 1 && (
        <p className="small muted" style={{ marginTop: -4 }}>
          {data.by_round.map(r => `${r.round_name}: ${r.complete}/${r.total} done`).join('  ·  ')}
        </p>
      )}

      <div className="toolbar">
        <select value={filter} onChange={e => setFilter(e.target.value)}>
          <option value="all">Everyone ({students.length})</option>
          <option value="complete">All formalities done</option>
          <option value="pending">Something still pending</option>
          <option value="notsignedin">Never signed in</option>
          <option value="noid">Signed in but no photo ID</option>
        </select>
        <select value={round} onChange={e => setRound(e.target.value)}>
          <option value="all">All rounds</option>
          {rounds.map(r => <option key={r} value={r}>{r}</option>)}
        </select>
        <input placeholder="Search name, email or roll no" value={q}
               onChange={e => setQ(e.target.value)} style={{ minWidth: 240 }} />
        <button className="ghost sm" onClick={load}>Refresh</button>
        <button className="ghost sm" onClick={exportCsv} disabled={!rows.length}>Export CSV</button>
        <span className="small muted">{rows.length} shown · updates every 15 seconds</span>
      </div>
      {err && <div className="error">{err}</div>}

      <div className="table-wrap">
        <table>
          <thead><tr>
            <th title="serial number from your batch sheet">#</th>
            <th>Name</th><th>Email</th><th>Round</th><th>Roll no</th>
            <th>Formalities</th><th>Attempt</th><th></th>
          </tr></thead>
          <tbody>
            {!data && <tr><td colSpan={8} className="muted">Loading…</td></tr>}
            {data && rows.length === 0 && (
              <tr><td colSpan={8} className="muted">Nobody matches that.</td></tr>
            )}
            {rows.map(s => (
              <tr key={s.email} style={s.complete ? undefined : { background: 'var(--warn-soft)' }}>
                <td className="mono small muted">{s.serial_no ?? '—'}</td>
                <td>
                  {s.full_name || s.listed_name || <span className="muted">—</span>}
                  {s.full_name && s.listed_name && s.full_name.trim().toLowerCase() !== s.listed_name.trim().toLowerCase() && (
                    <div className="small muted">listed as {s.listed_name}</div>
                  )}
                  {s.banned && <span className="badge blocked" style={{ marginLeft: 4 }}>banned</span>}
                </td>
                <td className="small mono">{s.email}</td>
                <td className="small">{s.round_name || <span className="muted">—</span>}</td>
                <td className="mono small">
                  {s.roll_no || <span className="muted">{s.roll_hint ? `${s.roll_hint}?` : '—'}</span>}
                </td>
                <td><Steps s={s} /></td>
                <td className="small">{s.attempt_status || <span className="muted">not started</span>}</td>
                <td style={{ whiteSpace: 'nowrap' }}>
                  {s.has_id && (
                    <button className="sm ghost" onClick={() => setViewing(s.roll_no)}>Photo ID</button>
                  )}
                  {s.roll_no
                    ? <button className="sm ghost" style={{ marginLeft: 4 }}
                              onClick={() => onOpen(s.roll_no)}>Open ›</button>
                    : !s.has_id && <span className="muted small"
                        title={s.last_seen_at ? `last seen ${fmtTime(s.last_seen_at)}` : ''}>—</span>}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {viewing && <IdViewer token={token} roll={viewing} onClose={() => setViewing(null)} />}
    </>
  )
}
