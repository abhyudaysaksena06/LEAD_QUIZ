import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { rpc } from '../lib/api'

const STATUS = {
  registered: { label: 'Registered', cls: 'not_started' },
  writing: { label: 'Writing', cls: 'in_progress' },
  submitted: { label: 'Submitted', cls: 'submitted' },
}
const words = s => (s && s.trim() ? s.trim().split(/\s+/).length : 0)
const when = iso => (iso ? new Date(iso).toLocaleString('en-IN', { dateStyle: 'short', timeStyle: 'medium' }) : '')
const REC = {
  advance: { label: 'Advance', cls: 'submitted' },
  borderline: { label: 'Borderline', cls: 'paused' },
  reject: { label: 'Reject', cls: 'blocked' },
}
const CRITERIA = ['evidence_discipline', 'track_depth', 'investor_call', 'clarity']
const sleep = ms => new Promise(r => setTimeout(r, ms))
const STOP_ALL = ['JUDGE_NOT_CONFIGURED', 'JUDGE_KEY_INVALID', 'ADMIN_SESSION_INVALID', 'DB_NOT_CONFIGURED']

/** One AI judgement via the server function (the API key lives only there). */
async function judgeTeam(token, email) {
  let r
  try {
    r = await fetch('/api/judge', { method: 'POST', headers: { 'Content-Type': 'application/json' },
                                    body: JSON.stringify({ token, email }) })
  } catch { throw Object.assign(new Error('Could not reach the AI judge. Check your connection.'), { code: 'NETWORK' }) }
  let body = null
  try { body = await r.json() } catch { /* not JSON: e.g. the function is not deployed */ }
  if (!r.ok || !body?.ok) {
    throw Object.assign(new Error(body?.message || `The AI judge is not available (HTTP ${r.status}).`),
                        { code: body?.code || 'JUDGE_UNAVAILABLE' })
  }
  return body
}

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
  const [sort, setSort] = useState('registered')
  const [judging, setJudging] = useState({})     // email -> true while that team is being judged
  const [batch, setBatch] = useState(null)       // { done, total, failed, running }
  const stopRef = useRef(false)

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
      (!t || [x.team_name, x.leader_name, x.email, x.leader_phone].some(v => (v || '').toLowerCase().includes(t))))
      .sort((a, b) => sort === 'ai' ? (b.ai?.total ?? -1) - (a.ai?.total ?? -1) : 0)
  }, [teams, q, track, status, sort])

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

  function remove(email, label) {
    if (!window.confirm(`Delete ${label} (${email}) completely — account, team and response? This cannot be undone. A copy is kept in the audit log.`)) return
    setOpen(null)
    act('admin_screening_delete', { p_email: email })
  }

  function setPassword(email) {
    const pw = window.prompt(`New password for ${email} (at least 8 characters). Tell the team leader; they will be signed out everywhere.`)
    if (pw == null) return
    if (pw.length < 8) { setErr('The password must be at least 8 characters.'); return }
    act('admin_screening_set_password', { p_email: email, p_password: pw })
  }

  async function judgeOne(email) {
    setJudging(j => ({ ...j, [email]: true })); setErr('')
    try { await judgeTeam(token, email); await load() }
    catch (e) {
      if (e.code === 'ADMIN_SESSION_INVALID' && onSessionInvalid) onSessionInvalid()
      else setErr(`AI judge: ${e.message}`)
    } finally { setJudging(j => { const n = { ...j }; delete n[email]; return n }) }
  }

  // Every submitted team without a current AI score, three at a time.
  async function judgeAll() {
    const queue = teams.filter(x => x.status === 'submitted' && (!x.ai || x.ai.stale)).map(x => x.email)
    if (!queue.length) return
    if (!window.confirm(`Judge ${queue.length} response(s) with AI? Each takes up to a minute and uses the Anthropic API key (roughly US$0.05–0.15 per response). Keep this tab open.`)) return
    stopRef.current = false; setErr('')
    const state = { done: 0, total: queue.length, failed: [], running: true }
    setBatch({ ...state })
    let fatal = null
    const worker = async () => {
      while (queue.length && !stopRef.current && !fatal) {
        const email = queue.shift()
        setJudging(j => ({ ...j, [email]: true }))
        for (let attempt = 0; ; attempt++) {
          try { await judgeTeam(token, email); break }
          catch (e) {
            if (STOP_ALL.includes(e.code)) { fatal = e; break }
            if (e.code === 'JUDGE_RATE_LIMITED' && attempt < 2) { await sleep(20000); continue }
            state.failed.push(`${teams.find(x => x.email === email)?.team_name || email}: ${e.message}`); break
          }
        }
        setJudging(j => { const n = { ...j }; delete n[email]; return n })
        state.done++; setBatch({ ...state })
      }
    }
    await Promise.all([worker(), worker(), worker()])
    state.running = false; setBatch({ ...state })
    if (fatal) {
      if (fatal.code === 'ADMIN_SESSION_INVALID' && onSessionInvalid) onSessionInvalid()
      else setErr(`AI judge stopped: ${fatal.message}`)
    }
    await load()
  }

  function exportCsv() {
    const header = ['team_name', 'leader_name', 'leader_phone', 'leader_email', 'track', 'status', 'how_submitted',
                    'registered_at', 'started_at', 'submitted_at',
                    'q1_prompt', 'q1_answer', 'q1_words', 'q2_prompt', 'q2_answer', 'q2_words',
                    'q3_prompt', 'q3_answer', 'q3_words', 'times_reopened',
                    'ai_total', 'ai_max', 'ai_recommendation', 'ai_evidence_discipline', 'ai_track_depth',
                    'ai_investor_call', 'ai_clarity', 'ai_summary', 'ai_strengths', 'ai_concerns', 'ai_flags',
                    'ai_out_of_date', 'ai_judged_at']
    const esc = v => `"${String(v ?? '').replace(/"/g, '""')}"`
    const lines = rows.map(x => {
      const tr = trackById[x.track] || {}
      const a = x.answers || []
      const p = tr.prompts || []
      return [x.team_name, x.leader_name, x.leader_phone, x.email, tr.label || x.track, STATUS[x.status]?.label || x.status,
              x.submit_reason === 'TIME_UP' ? 'time ran out' : x.submit_reason === 'MANUAL' ? 'submitted by team' : '',
              when(x.registered_at), when(x.started_at), when(x.submitted_at),
              p[0]?.title, a[0], words(a[0]), p[1]?.title, a[1], words(a[1]), p[2]?.title, a[2], words(a[2]),
              x.reopened_count,
              x.ai?.total, x.ai?.max_total, x.ai?.recommendation,
              ...CRITERIA.map(k => x.ai?.scores?.[k]?.score),
              x.ai?.summary, x.ai?.strengths, x.ai?.concerns, (x.ai?.integrity_flags || []).join('; '),
              x.ai ? (x.ai.stale ? 'yes' : 'no') : '', when(x.ai?.judged_at)].map(esc).join(',')
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
  const incomplete = data.incomplete || []

  return (
    <>
      <div className="stats">
        <div className="stat"><b>{teams.length}</b><span>Teams</span></div>
        <div className="stat" title="Created an account but have not entered their name, phone and team yet">
          <b style={{ color: incomplete.length ? 'var(--warn)' : undefined }}>{incomplete.length}</b><span>Sign-in not completed</span></div>
        {tracks.map(t => <div key={t.id} className="stat"><b>{count('track', t.id)}</b><span>{t.label}</span></div>)}
        <div className="stat"><b style={{ color: 'var(--brand)' }}>{count('status', 'writing')}</b><span>Writing now</span></div>
        <div className="stat"><b style={{ color: 'var(--ok)' }}>{count('status', 'submitted')}</b><span>Submitted</span></div>
        <div className="stat"><b>{teams.filter(x => x.ai && !x.ai.stale).length}</b><span>AI judged</span></div>
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
        <select value={sort} onChange={e => setSort(e.target.value)} aria-label="Sort">
          <option value="registered">Order registered</option>
          <option value="ai">AI score, high → low</option>
        </select>
        <span className="spacer" />
        <span className="small muted">{rows.length} shown</span>
        {batch?.running
          ? <button className="danger" onClick={() => { stopRef.current = true }}>Stop AI judging</button>
          : <button className="ghost" disabled={!(teams.filter(x => x.status === 'submitted' && (!x.ai || x.ai.stale)).length)} onClick={judgeAll}
                    title="Grades every submitted response that has no current AI score">
              AI-judge {teams.filter(x => x.status === 'submitted' && (!x.ai || x.ai.stale)).length} submitted</button>}
        <button onClick={exportCsv} disabled={!rows.length}>Download CSV</button>
      </div>
      {err && <div className="error">{err}</div>}
      {batch && (
        <div className={`status-box ${batch.failed.length ? 'wait' : 'ok'}`} style={{ marginBottom: 10 }}>
          {batch.running ? 'AI judging… ' : 'AI judging finished: '}<b>{batch.done}</b> of {batch.total}
          {batch.failed.length > 0 && <> · {batch.failed.length} failed
            <ul className="small" style={{ margin: '4px 0 0' }}>{batch.failed.map(f => <li key={f}>{f}</li>)}</ul></>}
          {!batch.running && <button className="sm ghost" style={{ marginLeft: 8 }} onClick={() => setBatch(null)}>Dismiss</button>}
        </div>
      )}

      <div className="table-wrap">
        <table>
          <thead><tr>
            <th>Team</th><th>Leader</th><th>Track</th><th>Status</th><th>Started</th><th>Submitted</th>
            <th>Words (Q1 / Q2 / Q3)</th><th>AI score</th><th></th>
          </tr></thead>
          <tbody>
            {rows.length === 0 && <tr><td colSpan={9} className="muted">No teams yet.</td></tr>}
            {rows.map(x => {
              const leftMs = x.status === 'writing' ? new Date(x.deadline) - (Date.now() + offset) : null
              return (
                <tr key={x.email}>
                  <td><b>{x.team_name}</b></td>
                  <td>{x.leader_name || '—'}<div className="small muted">{x.leader_phone} · {x.email}</div></td>
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
                  <td><AiCell team={x} judging={!!judging[x.email]} /></td>
                  <td style={{ whiteSpace: 'nowrap' }}>
                    <button className="sm ghost" onClick={() => setOpen(x.email)}>View</button>
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>

      {incomplete.length > 0 && (
        <details className="section" style={{ marginTop: 14 }}>
          <summary style={{ cursor: 'pointer' }}><b>{incomplete.length}</b> account(s) signed up but have not completed sign-in</summary>
          <table style={{ marginTop: 8 }}>
            <thead><tr><th>Email</th><th>Signed up</th><th></th></tr></thead>
            <tbody>{incomplete.map(a => (
              <tr key={a.email}><td>{a.email}</td><td>{when(a.created_at)}</td>
                <td style={{ whiteSpace: 'nowrap', textAlign: 'right' }}>
                  <button className="sm ghost" disabled={busy} onClick={() => setPassword(a.email)}>Set password…</button>{' '}
                  <button className="sm danger" disabled={busy} onClick={() => remove(a.email, 'this account')}>Delete</button>
                </td></tr>))}
            </tbody>
          </table>
        </details>
      )}

      {viewing && (
        <TeamDrawer team={viewing} track={trackById[viewing.track]} rubric={cfg.rubric} busy={busy}
                    judging={!!judging[viewing.email]} onJudge={() => judgeOne(viewing.email)}
                    onClose={() => setOpen(null)} onReopen={() => reopen(viewing)}
                    onPassword={() => setPassword(viewing.email)}
                    onDelete={() => remove(viewing.email, `"${viewing.team_name}"`)} />
      )}
    </>
  )
}

function AiCell({ team, judging }) {
  if (judging) return <span className="small muted">judging…</span>
  if (!team.ai) return <span className="muted">—</span>
  const r = REC[team.ai.recommendation]
  return (
    <span title={team.ai.summary || ''}>
      <b>{team.ai.total}</b><span className="muted">/{team.ai.max_total}</span>{' '}
      <span className={`badge ${r?.cls}`}>{r?.label}</span>
      {team.ai.stale && <div className="small" style={{ color: 'var(--warn)' }}>answers changed — re-judge</div>}
      {team.ai.integrity_flags?.length > 0 && <div className="small" style={{ color: 'var(--bad)' }}>⚑ {team.ai.integrity_flags.length} flag(s)</div>}
    </span>
  )
}

function AiVerdict({ team, judging, onJudge, busy }) {
  const ai = team.ai
  const canJudge = team.status === 'submitted'
  return (
    <div className="section">
      <div className="row" style={{ marginBottom: 6 }}>
        <h3 style={{ margin: 0 }}>AI judge</h3>
        <span className="spacer" />
        <button className="sm" disabled={!canJudge || judging || busy} onClick={onJudge}
                title={canJudge ? '' : 'Only submitted responses can be judged'}>
          {judging ? 'Judging…' : ai ? 'Re-judge' : 'Judge with AI'}
        </button>
      </div>
      {!ai ? <p className="small muted">{canJudge ? 'Not judged yet.' : 'Available once the team has submitted.'}</p> : <>
        <p style={{ margin: '4px 0' }}>
          <b style={{ fontSize: 20 }}>{ai.total}</b><span className="muted">/{ai.max_total}</span>{' '}
          <span className={`badge ${REC[ai.recommendation]?.cls}`}>{REC[ai.recommendation]?.label}</span>
        </p>
        {ai.stale && <div className="status-box wait small">The answers changed after this was judged. Re-judge for a current score.</div>}
        {ai.integrity_flags?.length > 0 && (
          <div className="error small"><b>Flags:</b> {ai.integrity_flags.join(' · ')}</div>
        )}
        <p className="small">{ai.summary}</p>
        {CRITERIA.map(k => ai.scores?.[k] && (
          <div key={k} className="small" style={{ margin: '6px 0' }}>
            <b>{ai.scores[k].title}: {ai.scores[k].score}/{ai.scores[k].max}</b>
            <div className="muted">{ai.scores[k].rationale}</div>
          </div>
        ))}
        {ai.strengths && <p className="small"><b>Strengths:</b> {ai.strengths}</p>}
        {ai.concerns && <p className="small"><b>Concerns:</b> {ai.concerns}</p>}
        {(ai.question_feedback || []).map(f => (
          <p key={f.question} className="small"><b>Q{f.question}:</b> {f.feedback}</p>
        ))}
        <p className="small muted" style={{ marginBottom: 0 }}>
          {ai.model} · {when(ai.judged_at)} · run by {ai.judged_by}. The AI saw only the answers, not the team's name or contact details.
          It assists screeners; the decision is yours.</p>
      </>}
    </div>
  )
}

function TeamDrawer({ team, track, rubric, busy, judging, onJudge, onClose, onReopen, onPassword, onDelete }) {
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
          <button className="sm ghost" disabled={busy} onClick={onPassword}>Set password…</button>
          <button className="sm danger" disabled={busy} onClick={onDelete}>Delete</button>
          <button className="sm" onClick={onClose}>Close</button>
        </div>
        <div className="drawer-body">
          <div>
            <div className="section">
              <dl className="kv">
                <dt>Leader</dt><dd>{team.leader_name || '—'}</dd>
                <dt>Mobile</dt><dd>{team.leader_phone ? <a href={`tel:+91${team.leader_phone}`}>{team.leader_phone}</a> : '—'}</dd>
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
            <AiVerdict team={team} judging={judging} onJudge={onJudge} busy={busy} />
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
