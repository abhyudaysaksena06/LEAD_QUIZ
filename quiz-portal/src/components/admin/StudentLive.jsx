import { useCallback, useEffect, useState } from 'react'
import { rpc } from '../../lib/api'
import ChatBox from '../ChatBox'
import { StatusBadge, fmtLeft, fmtTime } from './util'

const KIND_LABEL = {
  FULLSCREEN_EXIT: 'Left fullscreen',
  TAB_HIDDEN: 'Switched tab or minimised',
  WINDOW_BLUR: 'Focused another window',
  PRINTSCREEN: 'Pressed Print Screen',
  PASTE_BLOCKED: 'Tried to paste from outside',
  DEVTOOLS: 'Developer tools',
  CAMERA: 'Camera',
}
const label = k => KIND_LABEL[k] || k.replace(/_/g, ' ').toLowerCase()

function Row({ s, offset, token, onChanged, onOpen }) {
  const [open, setOpen] = useState(false)
  const attention = Number(s.unread) + Number(s.open_flags)
  const left = s.status === 'in_progress' ? new Date(s.deadline_at) - (Date.now() + offset) : null

  const loadChat = useCallback(() => rpc('admin_get_messages', { p_token: token, p_roll: s.roll_no }), [token, s.roll_no])
  const sendChat = useCallback(b => rpc('admin_send_message', { p_token: token, p_roll: s.roll_no, p_body: b }), [token, s.roll_no])

  async function resolve(flagId) {
    await rpc('admin_resolve_flags', { p_token: token, p_roll: s.roll_no, p_flag_id: flagId ?? null })
    onChanged()
  }

  return (
    <>
      <tr style={attention ? { background: 'var(--warn-soft)' } : undefined}>
        <td>
          <span title={s.active ? 'online now' : `last seen ${fmtTime(s.last_seen_at)}`}
                style={{ color: s.active ? 'var(--ok)' : 'var(--line)', fontSize: 16 }}>●</span>
        </td>
        <td className="mono"><b>{s.roll_no}</b></td>
        <td>{s.full_name || <span className="muted">—</span>}</td>
        <td className="small">{s.batch_name || '—'}</td>
        <td><StatusBadge status={s.banned ? 'banned' : s.status} /></td>
        <td className="mono small">{s.status === 'in_progress' ? fmtLeft(left) : '—'}</td>
        <td>
          {Number(s.open_flags) > 0 && (
            <span className="badge blocked" style={{ marginRight: 4 }}>⚠ {s.open_flags}</span>
          )}
          {Number(s.unread) > 0 && <span className="unread">{s.unread} msg</span>}
          {s.status === 'in_progress' && s.camera_ok === false && (
            <span className="badge" style={{ background: 'var(--warn-soft)', color: 'var(--warn)', marginLeft: 4 }}
                  title={s.camera_note || 'camera not reporting'}>
              camera: {s.camera_note || 'off'}
            </span>
          )}
          {attention === 0 && s.camera_ok !== false && <span className="muted small">—</span>}
        </td>
        <td style={{ whiteSpace: 'nowrap' }}>
          <button className="sm ghost" onClick={() => setOpen(o => !o)}>
            {open ? 'Hide' : attention ? `Review (${attention})` : 'Details'}
          </button>
          <button className="sm ghost" style={{ marginLeft: 4 }} onClick={() => onOpen(s.roll_no)}>Open ›</button>
        </td>
      </tr>

      {open && (
        <tr>
          <td colSpan={8} style={{ background: '#fafcfe' }}>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 360px', gap: 14, padding: '6px 2px 12px' }}>
              <div>
                <div className="row">
                  <b className="small">Violations</b>
                  <span className="spacer" />
                  {Number(s.open_flags) > 0 &&
                    <button className="sm" onClick={() => resolve(null)}>Resolve all</button>}
                </div>
                {(!s.flags || s.flags.length === 0) && (
                  <p className="muted small">Nothing outstanding. Resolved items are hidden for every proctor.</p>
                )}
                {(s.flags || []).map(f => (
                  <div key={f.id} className="ans" style={{ padding: '6px 0' }}>
                    <div className="row small">
                      <b>{label(f.kind)}</b>
                      <span className="muted">{fmtTime(f.created_at)}</span>
                      <span className="spacer" />
                      <button className="sm ghost" onClick={() => resolve(f.id)}>Resolve</button>
                    </div>
                  </div>
                ))}
              </div>

              <div style={{ display: 'grid', gridTemplateRows: 'auto 220px auto',
                            border: '1px solid var(--line)', borderRadius: 8, background: '#fff' }}>
                <div className="chat-head"><b className="small">Chat</b>
                  {s.assigned_to && <span className="badge" style={{ marginLeft: 6 }}>{s.assigned_to}</span>}
                </div>
                <ChatBox me="admin" load={loadChat} send={sendChat} pollMs={4000} />
              </div>
            </div>
          </td>
        </tr>
      )}
    </>
  )
}

export default function StudentLive({ token, onOpen }) {
  const [data, setData] = useState(null)
  const [offset, setOffset] = useState(0)
  const [filter, setFilter] = useState('attention')
  const [err, setErr] = useState('')
  const [, tick] = useState(0)

  const load = useCallback(async () => {
    try {
      const d = await rpc('admin_live', { p_token: token })
      setData(d); setOffset(new Date(d.server_now) - Date.now()); setErr('')
    } catch (e) { setErr(e.message) }
  }, [token])

  useEffect(() => {
    load()
    const t = setInterval(load, 5000)
    const c = setInterval(() => tick(x => x + 1), 1000)
    return () => { clearInterval(t); clearInterval(c) }
  }, [load])

  const students = data?.students || []
  const needing = students.filter(s => Number(s.unread) + Number(s.open_flags) > 0
    || (s.status === 'in_progress' && s.camera_ok === false))
  const live = students.filter(s => s.active)
  const rows = filter === 'attention' ? needing : filter === 'live' ? live : students

  return (
    <>
      <div className="stats">
        <div className="stat"><b style={{ color: 'var(--ok)' }}>{live.length}</b><span>Online now</span></div>
        <div className="stat"><b style={{ color: needing.length ? 'var(--bad)' : undefined }}>{needing.length}</b><span>Need attention</span></div>
        <div className="stat"><b>{students.filter(s => s.status === 'in_progress').length}</b><span>Writing</span></div>
        <div className="stat"><b>{students.length}</b><span>Students</span></div>
      </div>

      <div className="toolbar">
        <select value={filter} onChange={e => setFilter(e.target.value)}>
          <option value="attention">Needs attention ({needing.length})</option>
          <option value="live">Online now ({live.length})</option>
          <option value="all">Everyone ({students.length})</option>
        </select>
        <button className="ghost sm" onClick={load}>Refresh</button>
        <span className="small muted">Updates every 5 seconds · resolved items disappear for all proctors</span>
      </div>
      {err && <div className="error">{err}</div>}

      <div className="table-wrap">
        <table>
          <thead><tr>
            <th></th><th>Roll no</th><th>Name</th><th>Round</th><th>Status</th>
            <th>Time left</th><th>Notifications</th><th></th>
          </tr></thead>
          <tbody>
            {!data && <tr><td colSpan={8} className="muted">Loading…</td></tr>}
            {data && rows.length === 0 && (
              <tr><td colSpan={8} className="muted">
                {filter === 'attention' ? 'Nothing needs attention right now.' : 'Nobody here.'}
              </td></tr>
            )}
            {rows.map(s => (
              <Row key={s.roll_no} s={s} offset={offset} token={token} onChanged={load} onOpen={onOpen} />
            ))}
          </tbody>
        </table>
      </div>
    </>
  )
}
