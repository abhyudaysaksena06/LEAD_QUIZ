import { useCallback, useState } from 'react'
import { rpc } from '../../lib/api'
import ChatBox from '../ChatBox'
import { StatusBadge, fmtTime } from './util'

export default function Inbox({ token, students, me, admins = [], onOpenStudent, onChanged }) {
  const [sel, setSel] = useState(null)
  const [tab, setTab] = useState('mine')
  const [newRoll, setNewRoll] = useState('')
  const [broadcast, setBroadcast] = useState('')
  const [note, setNote] = useState('')

  const hasMessages = s => s.last_student_message_at
  const open = students.filter(s => hasMessages(s) && !s.thread_resolved)
  const mine = open.filter(s => s.assigned_to === me)
  const others = open.filter(s => s.assigned_to !== me)
  const resolved = students.filter(s => hasMessages(s) && s.thread_resolved)

  const list = (tab === 'mine' ? mine : tab === 'all' ? open : resolved)
    .slice()
    .sort((a, b) => (b.unread - a.unread) ||
      (new Date(b.last_student_message_at || 0) - new Date(a.last_student_message_at || 0)))

  const selected = students.find(s => s.roll_no === sel)
  const load = useCallback(() => rpc('admin_get_messages', { p_token: token, p_roll: sel }), [token, sel])
  const send = useCallback(body => rpc('admin_send_message', { p_token: token, p_roll: sel, p_body: body }), [token, sel])

  async function act(fn, roll) {
    try { await rpc(fn, { p_token: token, p_roll: roll }); onChanged() }
    catch (e) { setNote(e.message) }
  }

  function openRoll(e) {
    e.preventDefault()
    const r = newRoll.trim()
    if (!students.some(s => s.roll_no === r)) { setNote(`No student with roll number ${r}.`); return }
    setSel(r); setNewRoll(''); setNote('')
  }

  async function sendBroadcast(e) {
    e.preventDefault()
    if (!broadcast.trim()) return
    if (!window.confirm(`Send this message to ALL ${students.length} students?`)) return
    try {
      const r = await rpc('admin_broadcast', { p_token: token, p_body: broadcast.trim() })
      setNote(`Broadcast sent to ${r.recipients} students.`); setBroadcast(''); onChanged()
    } catch (err) { setNote(err.message) }
  }

  return (
    <>
      {open.reduce((n, s) => n + Number(s.unread || 0), 0) > 0 && (
        <div className="error" style={{ background: 'var(--warn-soft)', color: 'var(--warn)',
                                        fontSize: 14, fontWeight: 600 }}>
          🔔 {open.reduce((n, s) => n + Number(s.unread || 0), 0)} unread message(s) from{' '}
          {open.filter(s => Number(s.unread) > 0).length} student(s)
          {mine.filter(s => Number(s.unread) > 0).length > 0 &&
            <> · <b>{mine.filter(s => Number(s.unread) > 0).length} assigned to you</b></>}
        </div>
      )}

      {/* who is on duty and how loaded they are */}
      <div className="toolbar" style={{ gap: 14 }}>
        {admins.map(a => (
          <span key={a.username} className="small" title={a.active ? 'online' : `last seen ${fmtTime(a.last_seen_at)}`}
                style={{ opacity: a.active ? 1 : 0.45 }}>
            <span style={{ color: a.active ? 'var(--ok)' : 'var(--muted)' }}>●</span>{' '}
            <b>{a.username === me ? 'You' : (a.display_name || a.username)}</b>{' '}
            {a.open_threads} open{a.unread > 0 ? ` · ${a.unread} unread` : ''}
          </span>
        ))}
        {admins.every(a => !a.active) && <span className="small muted">nobody marked active yet</span>}
      </div>

      <form className="toolbar" onSubmit={sendBroadcast}>
        <input style={{ flex: 1 }} value={broadcast} onChange={e => setBroadcast(e.target.value)}
               placeholder="Broadcast to every student (e.g. “Q5 has a typo — it won’t be graded”)" maxLength={2000} />
        <button disabled={!broadcast.trim()}>Broadcast</button>
      </form>
      {note && <div className="error">{note}</div>}

      <div className="inbox">
        <div className="threads">
          <div className="tabs" style={{ padding: 0 }}>
            <button className={tab === 'mine' ? 'active' : ''} onClick={() => setTab('mine')}>Mine ({mine.length})</button>
            <button className={tab === 'all' ? 'active' : ''} onClick={() => setTab('all')}>All ({open.length})</button>
            <button className={tab === 'done' ? 'active' : ''} onClick={() => setTab('done')}>Done ({resolved.length})</button>
          </div>

          <form className="row" style={{ padding: 10, borderBottom: '1px solid var(--line)' }} onSubmit={openRoll}>
            <input value={newRoll} onChange={e => setNewRoll(e.target.value)} placeholder="Message roll no…" />
            <button className="sm">Open</button>
          </form>

          {list.length === 0 && (
            <p className="muted small" style={{ padding: 12 }}>
              {tab === 'mine' ? 'Nothing assigned to you right now.' : 'No conversations here.'}
            </p>
          )}
          {list.map(s => (
            <div key={s.roll_no} className={`thread ${s.roll_no === sel ? 'active' : ''}`} onClick={() => setSel(s.roll_no)}>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div><b className="mono">{s.roll_no}</b> <StatusBadge status={s.status} /></div>
                <div className="small muted">
                  {fmtTime(s.last_student_message_at)}
                  {s.assigned_to && s.assigned_to !== me && <> · <b>{s.assigned_to}</b></>}
                  {!s.assigned_to && <> · <b style={{ color: 'var(--warn)' }}>unassigned</b></>}
                </div>
              </div>
              {s.unread > 0 && <span className="unread">{s.unread}</span>}
            </div>
          ))}
        </div>

        <div className="thread-view">
          {!sel ? (
            <p className="muted" style={{ padding: 20 }}>
              Select a conversation. <b>Mine</b> shows the students routed to you — queries are shared evenly
              between the proctors who are signed in.
            </p>
          ) : (
            <>
              <div className="chat-head">
                <b className="mono">{sel}</b>
                {selected && <span style={{ marginLeft: 8 }}><StatusBadge status={selected.status} /></span>}
                {selected?.assigned_to && (
                  <span className="badge" style={{ marginLeft: 8 }}>
                    {selected.assigned_to === me ? 'yours' : selected.assigned_to}
                  </span>
                )}
                <span className="spacer" />
                {selected?.assigned_to !== me && (
                  <button className="sm" onClick={() => act('admin_claim_thread', sel)}>Take over</button>
                )}
                {selected && !selected.thread_resolved && (
                  <button className="sm ghost" onClick={() => act('admin_resolve_thread', sel)}>Mark done</button>
                )}
                <button className="sm ghost" onClick={() => onOpenStudent(sel)}>Open student ›</button>
              </div>
              <ChatBox key={sel} me="admin" load={load} send={send} pollMs={3000} />
            </>
          )}
        </div>
      </div>
    </>
  )
}
