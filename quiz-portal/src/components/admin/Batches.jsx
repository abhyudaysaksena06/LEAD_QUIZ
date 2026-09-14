import { useEffect, useState } from 'react'
import { rpc } from '../../lib/api'
import { fmtLeft } from './util'

export default function Batches({ token, batches, config, onChanged }) {
  const [name, setName] = useState('')
  const [dur, setDur] = useState({})
  const [win, setWin] = useState({})
  const [err, setErr] = useState('')
  const [busy, setBusy] = useState(false)
  const [, tick] = useState(0)

  useEffect(() => {
    const t = setInterval(() => tick(x => x + 1), 1000)
    return () => clearInterval(t)
  }, [])

  async function act(fn, args, confirmText) {
    if (confirmText && !window.confirm(confirmText)) return
    setBusy(true); setErr('')
    try { await rpc(fn, { p_token: token, ...args }); onChanged() }
    catch (e) { setErr(e.message) }
    finally { setBusy(false) }
  }

  async function create(e) {
    e.preventDefault()
    if (!name.trim()) return
    setBusy(true); setErr('')
    try { await rpc('admin_create_batch', { p_token: token, p_name: name.trim() }); setName(''); onChanged() }
    catch (e) { setErr(e.message) }
    finally { setBusy(false) }
  }

  return (
    <>
      <p className="muted small" style={{ maxWidth: 720 }}>
        Students can only press <b>Start</b> once their round is open. Opening a round starts its
        <b> window</b> (default 30 minutes): each student gets their own <b>{config?.duration_minutes ?? 15} minutes</b> to
        answer, and when the window shuts <b>everything still open is submitted — paused attempts included</b>.
        A student starting late gets whatever is left of the window. Each student still gets <b>one attempt only</b>.
        {!config?.exam_open && <><br /><b style={{ color: 'var(--bad)' }}>The master switch in Settings is OFF, so nobody can start regardless of batch.</b></>}
      </p>

      {err && <div className="error">{err}</div>}

      <div className="table-wrap" style={{ marginBottom: 14 }}>
        <table>
          <thead><tr>
            <th>Batch</th><th>Status</th><th>Students</th><th>Not started</th><th>Writing</th>
            <th>Finished</th><th>Each student</th><th>Round window</th><th></th>
          </tr></thead>
          <tbody>
            {batches.length === 0 && <tr><td colSpan={9} className="muted">No batches yet.</td></tr>}
            {batches.map(b => {
              const edited = dur[b.id] !== undefined && String(dur[b.id]) !== String(b.duration_minutes ?? '')
              const winEdited = win[b.id] !== undefined && String(win[b.id]) !== String(b.window_minutes ?? '')
              const closesIn = b.is_open && b.closes_at ? new Date(b.closes_at) - Date.now() : null
              return (
                <tr key={b.id}>
                  <td><b>{b.name}</b></td>
                  <td>
                    <span className={`badge ${b.is_open ? 'submitted' : 'blocked'}`}>{b.is_open ? 'OPEN' : 'CLOSED'}</span>
                    {closesIn != null && (
                      <div className="small" style={{ color: closesIn <= 60000 ? 'var(--bad)' : 'var(--muted)' }}>
                        {closesIn > 0 ? `closes in ${fmtLeft(closesIn)}` : 'window closed'}
                      </div>
                    )}
                  </td>
                  <td>{b.students}</td>
                  <td>{b.not_started}</td>
                  <td style={{ color: b.in_progress ? 'var(--brand)' : undefined, fontWeight: b.in_progress ? 700 : 400 }}>{b.in_progress}</td>
                  <td>{b.finished}</td>
                  <td>
                    <div className="row">
                      <input type="number" min="1" max="600" style={{ width: 80 }}
                             placeholder={`${config?.duration_minutes ?? 15}`}
                             value={dur[b.id] ?? (b.duration_minutes ?? '')}
                             onChange={e => setDur(d => ({ ...d, [b.id]: e.target.value }))} />
                      {edited && (
                        <button className="sm" disabled={busy}
                                onClick={() => act('admin_update_batch', {
                                  p_batch_id: b.id, p_name: null,
                                  p_duration_minutes: dur[b.id] === '' ? null : Number(dur[b.id]),
                                })}>Save</button>
                      )}
                    </div>
                  </td>
                  <td>
                    <div className="row">
                      <input type="number" min="1" max="600" style={{ width: 80 }} placeholder="30"
                             value={win[b.id] ?? (b.window_minutes ?? '')}
                             onChange={e => setWin(w => ({ ...w, [b.id]: e.target.value }))} />
                      {winEdited && (
                        <button className="sm" disabled={busy}
                                onClick={() => act('admin_update_batch', {
                                  p_batch_id: b.id, p_name: null, p_duration_minutes: null,
                                  p_window_minutes: Number(win[b.id]) || null,
                                })}>Save</button>
                      )}
                    </div>
                  </td>
                  <td style={{ whiteSpace: 'nowrap' }}>
                    {b.is_open
                      ? <button className="sm ghost" disabled={busy}
                                onClick={() => act('admin_set_batch_open', { p_batch_id: b.id, p_open: false },
                                  `Close ${b.name}? Students who have not started yet will no longer be able to. Students already writing continue.`)}>
                          Close
                        </button>
                      : <button className="sm success" disabled={busy}
                                onClick={() => act('admin_set_batch_open', { p_batch_id: b.id, p_open: true },
                                  `Start the quiz for ${b.name}? Its ${b.students} student(s) will be able to begin.`)}>
                          ▶ Start batch
                        </button>}
                    {b.in_progress > 0 && (
                      <button className="sm danger" disabled={busy} style={{ marginLeft: 6 }}
                              onClick={() => act('admin_force_submit_batch', { p_batch_id: b.id },
                                `Submit now for all ${b.in_progress} student(s) still writing in ${b.name}? Their answers are kept and graded.`)}>
                        Submit all
                      </button>
                    )}
                    <button className="sm ghost" disabled={busy} style={{ marginLeft: 6 }}
                            onClick={() => act('admin_delete_batch', { p_batch_id: b.id }, `Delete ${b.name}?`)}>
                      Delete
                    </button>
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>

      <form className="section" style={{ maxWidth: 420 }} onSubmit={create}>
        <h3>New batch</h3>
        <div className="row">
          <input value={name} onChange={e => setName(e.target.value)} placeholder="e.g. Batch 2 — 11:30 AM" />
          <button disabled={busy || !name.trim()}>Create</button>
        </div>
        <p className="small muted" style={{ marginTop: 8 }}>
          New batches start <b>closed</b>. Assign students to it in the <b>Students</b> tab.
        </p>
      </form>
    </>
  )
}
