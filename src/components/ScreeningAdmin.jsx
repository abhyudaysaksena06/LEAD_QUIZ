import { useCallback, useEffect, useMemo, useState } from 'react'
import { rpc } from '../lib/api'

const STATUS = {
  registered: { label: 'Registered', cls: 'not_started' },
  writing: { label: 'Writing', cls: 'in_progress' },
  submitted: { label: 'Submitted', cls: 'submitted' },
}
const words = s => (s && s.trim() ? s.trim().split(/\s+/).length : 0)
const when = iso => (iso ? new Date(iso).toLocaleString('en-IN', { dateStyle: 'short', timeStyle: 'medium' }) : '')
const clock = iso => (iso ? new Date(iso).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' }) : '—')

/** PRIMUS 2026 screening round: every team's registration and written response. */
export default function ScreeningResponses({ token, onSessionInvalid }) {
  const [data, setData] = useState(null)
  const [err, setErr] = useState('')
  const [q, setQ] = useState('')
  const [track, setTrack] = useState('all')
  const [status, setStatus] = useState('all')
  const [open, setOpen] = useState(null)        // email of the team being viewed
  const [minutes, setMinutes] = useState('')
  const [busy, setBusy] = useState(false)
  const [offset, setOffset] = useState(0)
  const [, tick] = useState(0)

  const load = useCallback(async () => {
    try {
      const d = await rpc('admin_screening', { p_token: token })
      setData(d); setOffset(new Date(d.server_now) - Date.now()); setErr('')
      setMinutes(m => (m === '' ? String(d.config.duration_minutes) : m))
    } catch (e) {
      if (e.code === 'ADMIN_SESSION_INVALID' && onSessionInvalid) onSessionInvalid()
      else setErr(e.message)
    }
  }, [token, onSessionInvalid])

  useEffect(() => {
    load()
    const t = setInterval(() => { if (!document.hidden) load() }, 10000)
    const c = setInterval(() => tick(x => x + 1), 1000)
    return () => { clearInterval(t); clearInterval(c) }
  }, [load])

  const tracks = useMemo(() => data?.tracks || [], [data])
  const trackById = useMemo(() => Object.fromEntries(tracks.map(t => [t.id, t])), [tracks])
  const teams = useMemo(() => data?.teams || [], [data])
  const rows = useMemo(() => {
    const t = q.trim().toLowerCase()
    return teams.filter(x =>
      (track === 'all' || x.track === track) &&
      (status === 'all' || x.status === status) &&
      (!t || [x.team_name, x.leader_name, x.email].some(v => (v || '').toLowerCase().includes(t))))
  }, [teams, q, track, status])

  async function act(fn, args) {
    setBusy(true)
    try { await rpc(fn, { p_token: token, ...args }); await load() }
    catch (e) { setErr(e.message) }
    finally { setBusy(false) }
  }

  function saveSettings(isOpen) {
    const m = Number(minutes)
    if (!Number.isInteger(m) || m < 1 || m > 180) { setErr('Duration must be a whole number of minutes, 1–180.'); return }
    act('admin_screening_settings', { p_is_open: isOpen, p_duration_minutes: m })
  }

  function reopen(team) {
    const m = window.prompt(`Give "${team.team_name}" more time. Minutes to add (their saved answers are kept):`, '5')
    if (m == null) return
    const n = Number(m)
    if (!Number.isInteger(n) || n < 1 || n > 60) { setErr('Minutes must be a whole number, 1–60.'); return }
    act('admin_screening_reopen', { p_email: team.email, p_minutes: n })
  }

  function remove(team) {
    if (!window.confirm(`Delete "${team.team_name}" (${team.email}) and its response? This cannot be undone. A copy is kept in the audit log.`)) return
    setOpen(null)
    act('admin_screening_delete', { p_email: team.email })
  }

  function exportCsv() {
    const header = ['team_name', 'leader_name', 'leader_email', 'track', 'status', 'how_submitted',
                    'registered_at', 'started_at', 'submitted_at',
                    'q1_prompt', 'q1_answer', 'q1_words', 'q2_prompt', 'q2_answer', 'q2_words',
                    'q3_prompt', 'q3_answer', 'q3_words', 'times_reopened']
    const esc = v => `"${String(v ?? '').replace(/"/g, '""')}"`
    const lines = rows.map(x => {
      const tr = trackById[x.track] || {}
      const a = x.answers || []
      const p = tr.prompts || []
      return [x.team_name, x.leader_name, x.email, tr.label || x.track, STATUS[x.status]?.label || x.status,
              x.submit_reason === 'TIME_UP' ? 'time ran out' : x.submit_reason === 'MANUAL' ? 'submitted by team' : '',
              when(x.registered_at), when(x.started_at), when(x.submitted_at),
              p[0]?.title, a[0], words(a[0]), p[1]?.title, a[1], words(a[1]), p[2]?.title, a[2], words(a[2]),
              x.reopened_count].map(esc).join(',')
    })
    // the BOM makes Excel read the file as UTF-8, so ₹ and names survive
    const csv = '﻿' + [header.join(','), ...lines].join('\r\n')
    const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' }))
    const a = document.createElement('a')
    a.href = url
    a.download = `primus-screening-responses-${new Date().toISOString().slice(0, 16).replace(/[:T]/g, '-')}.csv`
    a.click()
    setTimeout(() => URL.revokeObjectURL(url), 1000)
  }

  if (!data) return err ? <div className="error">{err}</div> : <p className="muted">Loading…</p>

  const count = (k, v) => teams.filter(x => x[k] === v).length
  const cfg = data.config
  const viewing = open && teams.find(x => x.email === open)

  return (
    <>
      <div className="stats">
        <div className="stat"><b>{teams.length}</b><span>Teams</span></div>
        {tracks.map(t => <div key={t.id} className="stat"><b>{count('track', t.id)}</b><span>{t.label}</span></div>)}
        <div className="stat"><b style={{ color: 'var(--brand)' }}>{count('status', 'writing')}</b><span>Writing now</span></div>
        <div className="stat"><b style={{ color: 'var(--ok)' }}>{count('status', 'submitted')}</b><span>Submitted</span></div>
      </div>

      <div className="section">
        <div className="row wrap">
          <b>Screening round</b>
          <span className={`badge ${cfg.is_open ? 'submitted' : 'blocked'}`}>{cfg.is_open ? 'OPEN' : 'CLOSED'}</span>
          <span className="small muted">Teams can register and start only while it is open. Teams already writing can always finish.</span>
          <span className="spacer" />
          <label htmlFor="scmin" style={{ margin: 0 }}>Minutes</label>
          <input id="scmin" type="number" min={1} max={180} value={minutes}
                 onChange={e => setMinutes(e.target.value)} style={{ width: 80 }} />
          <button className="ghost" disabled={busy} onClick={() => saveSettings(cfg.is_open)}>Save</button>
          <button className={cfg.is_open ? 'danger' : 'success'} disabled={busy} onClick={() => saveSettings(!cfg.is_open)}>
            {cfg.is_open ? 'Close round' : 'Open round'}
          </button>
        </div>
        <p className="small muted" style={{ margin: '8px 0 0' }}>
          Candidate page: <code>{window.location.origin}</code> · a new duration applies to teams that start after you save it.
        </p>
      </div>

      <div className="toolbar">
        <input value={q} onChange={e => setQ(e.target.value)} placeholder="Search team, leader or email" />
        <select value={track} onChange={e => setTrack(e.target.value)}>
          <option value="all">All tracks</option>
          {tracks.map(t => <option key={t.id} value={t.id}>{t.label}</option>)}
        </select>
        <select value={status} onChange={e => setStatus(e.target.value)}>
          <option value="all">All statuses</option>
          {Object.entries(STATUS).map(([k, v]) => <option key={k} value={k}>{v.label}</option>)}
        </select>
        <span className="spacer" />
        <span className="small muted">{rows.length} shown</span>
        <button onClick={exportCsv} disabled={!rows.length}>Download CSV</button>
      </div>
      {err && <div className="error">{err}</div>}

      <div className="table-wrap">
        <table>
          <thead><tr>
            <th>Team</th><th>Leader</th><th>Track</th><th>Status</th><th>Started</th><th>Submitted</th>
            <th>Words (Q1 / Q2 / Q3)</th><th></th>
          </tr></thead>
          <tbody>
            {rows.length === 0 && <tr><td colSpan={8} className="muted">No teams yet.</td></tr>}
            {rows.map(x => {
              const leftMs = x.status === 'writing' ? new Date(x.deadline) - (Date.now() + offset) : null
              return (
                <tr key={x.email}>
                  <td><b>{x.team_name}</b></td>
                  <td>{x.leader_name || '—'}<div className="small muted">{x.email}</div></td>
                  <td>{trackById[x.track]?.label || x.track}</td>
                  <td>
                    <span className={`badge ${STATUS[x.status]?.cls}`}>{STATUS[x.status]?.label}</span>
                    {leftMs != null && <div className="small muted">{leftMs > 0 ? `${Math.floor(leftMs / 60000)}:${String(Math.floor(leftMs / 1000) % 60).padStart(2, '0')} left` : 'closing…'}</div>}
                    {x.submit_reason === 'TIME_UP' && <div className="small muted">time ran out</div>}
                    {x.reopened_count > 0 && <div className="small muted">reopened ×{x.reopened_count}</div>}
                  </td>
                  <td>{clock(x.started_at)}</td>
                  <td>{clock(x.submitted_at)}</td>
                  <td className="mono">{(x.answers || []).map(words).join(' / ')}</td>
                  <td style={{ whiteSpace: 'nowrap' }}>
                    <button className="sm ghost" onClick={() => setOpen(x.email)}>View</button>
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>

      {viewing && (
        <TeamDrawer team={viewing} track={trackById[viewing.track]} rubric={cfg.rubric} busy={busy}
                    onClose={() => setOpen(null)} onReopen={() => reopen(viewing)} onDelete={() => remove(viewing)} />
      )}
    </>
  )
}

function TeamDrawer({ team, track, rubric, busy, onClose, onReopen, onDelete }) {
  useEffect(() => {
    const k = e => { if (e.key === 'Escape') onClose() }
    window.addEventListener('keydown', k)
    return () => window.removeEventListener('keydown', k)
  }, [onClose])

  const prompts = track?.prompts || []
  return (
    <>
      <div className="drawer-bg" onClick={onClose} />
      <aside className="drawer">
        <div className="drawer-head">
          <b>{team.team_name}</b>
          <span className={`badge ${STATUS[team.status]?.cls}`}>{STATUS[team.status]?.label}</span>
          <span className="badge">{track?.label}</span>
          <span className="spacer" />
          {team.started_at && <button className="sm ghost" disabled={busy} onClick={onReopen}>
            {team.status === 'submitted' ? 'Reopen…' : 'Add time…'}</button>}
          <button className="sm danger" disabled={busy} onClick={onDelete}>Delete</button>
          <button className="sm" onClick={onClose}>Close</button>
        </div>
        <div className="drawer-body">
          <div>
            <div className="section">
              <dl className="kv">
                <dt>Leader</dt><dd>{team.leader_name || '—'}</dd>
                <dt>Email</dt><dd>{team.email}</dd>
                <dt>Registered</dt><dd>{when(team.registered_at) || '—'}</dd>
                <dt>Started</dt><dd>{when(team.started_at) || 'not yet'}</dd>
                <dt>Submitted</dt><dd>{when(team.submitted_at) || '—'}
                  {team.submit_reason === 'TIME_UP' && ' (time ran out)'}</dd>
                <dt>Autosaves</dt><dd>{team.save_count}</dd>
              </dl>
            </div>
            <div className="section">
              <h3>Response</h3>
              {prompts.map((p, i) => (
                <div key={i} className="ans">
                  <b>{i + 1}. {p.title}</b> <span className="small muted">· {words(team.answers?.[i])} words</span>
                  <div className="small muted" style={{ margin: '2px 0 6px' }}>{p.body}</div>
                  <div className="sc-readonly">{team.answers?.[i] || <span className="muted">(no answer)</span>}</div>
                </div>
              ))}
            </div>
          </div>
          <div>
            <div className="section">
              <h3>{track?.label} mandate</h3>
              <p className="small">{track?.mandate}</p>
            </div>
            <div className="section">
              <h3>What screeners look for</h3>
              {(track?.signals || []).map(s => (
                <p key={s.title} className="small"><b>{s.title}:</b> {s.body}</p>
              ))}
            </div>
            <div className="section">
              <h3>Rubric · 25 points</h3>
              {(rubric || []).map(r => (
                <p key={r.title} className="small"><b>{r.title} ({r.points})</b> — {r.body}</p>
              ))}
            </div>
          </div>
        </div>
      </aside>
    </>
  )
}
