import { useCallback, useEffect, useMemo, useState } from 'react'
import { rpc } from '../../lib/api'
import { fmtTime } from './util'

export function IdViewer({ token, roll, onClose }) {
  const [doc, setDoc] = useState(null)
  const [err, setErr] = useState('')
  useEffect(() => {
    rpc('admin_get_id_document', { p_token: token, p_roll: roll })
      .then(d => (d.found ? setDoc(d) : setErr('No ID was uploaded for this student.')))
      .catch(e => setErr(e.message))
  }, [token, roll])
  return (
    <div className="overlay above-drawer" onClick={onClose}>
      <div className="card" style={{ maxWidth: 720 }} onClick={e => e.stopPropagation()}>
        <div className="row">
          <b className="mono">{roll}</b><span className="spacer" />
          <button className="sm ghost" onClick={onClose}>Close ✕</button>
        </div>
        {err && <div className="error">{err}</div>}
        {doc && <>
          <img src={`data:${doc.mime};base64,${doc.data_b64}`} alt={`ID for ${roll}`}
               style={{ width: '100%', borderRadius: 6, marginTop: 10 }} />
          <p className="small muted">Uploaded {fmtTime(doc.uploaded_at)} · {Math.round(doc.bytes / 1024)} KB</p>
        </>}
        {!doc && !err && <p className="muted">Loading…</p>}
      </div>
    </div>
  )
}

export default function Registrations({ token, batches, registration, onChanged }) {
  const [rows, setRows] = useState(null)
  const [text, setText] = useState('')
  const [batchId, setBatchId] = useState(String(batches[0]?.id ?? ''))
  const [filter, setFilter] = useState('all')
  const [round, setRound] = useState('all')
  const [q, setQ] = useState('')
  const [msg, setMsg] = useState('')
  const [busy, setBusy] = useState(false)
  const [viewing, setViewing] = useState(null)

  const load = useCallback(async () => {
    try { setRows(await rpc('admin_list_allowlist', { p_token: token })) }
    catch (e) { setMsg(e.message) }
  }, [token])
  useEffect(() => { load() }, [load])

  async function add(e) {
    e.preventDefault()
    // accepts "email" or "email, name, roll" per line
    const parsed = text.split('\n').map(l => l.trim()).filter(Boolean).map(l => {
      const [email, full_name, roll_hint] = l.split(/[,\t]/).map(x => (x || '').trim())
      return { email, full_name: full_name || null, roll_hint: roll_hint || null }
    })
    const bad = parsed.filter(r => !r.email.includes('@'))
    if (bad.length) { setMsg(`${bad.length} line(s) don't look like an email address.`); return }
    setBusy(true)
    try {
      const r = await rpc('admin_add_allowlist', {
        p_token: token, p_rows: parsed, p_batch_id: batchId ? Number(batchId) : null })
      setMsg(`${r.count} email(s) authorised.`); setText(''); await load(); onChanged()
    } catch (err) { setMsg(err.message) }
    finally { setBusy(false) }
  }

  async function move(email, newBatch) {
    try {
      await rpc('admin_set_allowlist_batch', { p_token: token, p_emails: [email], p_batch_id: Number(newBatch) })
      await load(); onChanged()
    } catch (e) { setMsg(e.message) }
  }

  async function remove(email) {
    if (!window.confirm(`Remove ${email} from the authorised list?`)) return
    try { await rpc('admin_remove_allowlist', { p_token: token, p_email: email }); await load(); onChanged() }
    catch (e) { setMsg(e.message) }
  }

  // Search matches name (either the sheet's or the one they typed), roll number,
  // email, or the serial number from the batch sheet.
  const list = useMemo(() => {
    const t = q.trim().toLowerCase()
    return (rows || []).filter(r => {
      if (filter === 'pending' && r.claimed_by) return false
      if (filter === 'done' && !r.claimed_by) return false
      if (round !== 'all' && String(r.batch_id ?? '') !== round) return false
      if (!t) return true
      return [r.registered_name, r.full_name, r.claimed_by, r.roll_hint, r.email,
              r.serial_no == null ? '' : String(r.serial_no)]
        .some(v => (v || '').toLowerCase().includes(t))
    })
  }, [rows, filter, round, q])

  const perRound = useMemo(() => {
    const m = new Map()
    for (const r of rows || []) {
      const k = r.batch_name || 'Unassigned'
      const v = m.get(k) || { total: 0, done: 0 }
      v.total += 1
      if (r.claimed_by) v.done += 1
      m.set(k, v)
    }
    return [...m.entries()].sort((a, b) => a[0].localeCompare(b[0]))
  }, [rows])

  return (
    <>
      <div className="stats">
        <div className="stat"><b>{registration?.allowlisted ?? 0}</b><span>Emails authorised</span></div>
        <div className="stat"><b style={{ color: 'var(--ok)' }}>{registration?.registered ?? 0}</b><span>Registered</span></div>
        <div className="stat"><b style={{ color: 'var(--warn)' }}>{registration?.pending ?? 0}</b><span>Not yet registered</span></div>
      </div>

      <form className="section" style={{ maxWidth: 760 }} onSubmit={add}>
        <h3>Authorise Google accounts</h3>
        <p className="small muted">
          One per line: <code>email</code>, or <code>email, name, roll number</code> to pre-fill their form.
          Only these addresses can sign in. Students then register themselves with their name,
          roll number and a photo ID.
        </p>
        <textarea rows={6} value={text} onChange={e => setText(e.target.value)}
                  style={{ fontFamily: 'var(--mono)', fontSize: 13 }}
                  placeholder={'student1@gmail.com\nstudent2@gmail.com, Priya Sharma, 1025030923'} />
        <div className="row" style={{ marginTop: 8 }}>
          <span className="small">Add to</span>
          <select value={batchId} onChange={e => setBatchId(e.target.value)} style={{ width: 'auto' }}>
            {batches.map(b => <option key={b.id} value={String(b.id)}>{b.name}</option>)}
          </select>
          <button disabled={busy || !text.trim()}>{busy ? 'Saving…' : 'Authorise'}</button>
        </div>
        {msg && <p className="small" style={{ marginTop: 8 }}>{msg}</p>}
      </form>

      {perRound.length > 1 && (
        <p className="small muted">
          {perRound.map(([name, v]) => `${name}: ${v.done}/${v.total} registered`).join('  ·  ')}
        </p>
      )}

      <div className="toolbar">
        <input placeholder="Search name, roll number, email or sheet no"
               value={q} onChange={e => setQ(e.target.value)} style={{ minWidth: 260 }} />
        <select value={round} onChange={e => setRound(e.target.value)}>
          <option value="all">All rounds</option>
          {batches.map(b => <option key={b.id} value={String(b.id)}>{b.name}</option>)}
        </select>
        <select value={filter} onChange={e => setFilter(e.target.value)}>
          <option value="all">All</option>
          <option value="pending">Not yet registered</option>
          <option value="done">Registered</option>
        </select>
        <button className="ghost sm" onClick={load}>Refresh</button>
        {(q || round !== 'all' || filter !== 'all') && (
          <button className="ghost sm" onClick={() => { setQ(''); setRound('all'); setFilter('all') }}>
            Clear
          </button>
        )}
        <span className="small muted">{list.length} of {(rows || []).length} shown</span>
      </div>

      <div className="table-wrap">
        <table>
          <thead><tr>
            <th title="serial number from your batch sheet">#</th>
            <th>Email</th><th>Round</th><th>Status</th><th>Name</th><th>Roll no</th><th>ID</th><th></th>
          </tr></thead>
          <tbody>
            {!rows && <tr><td colSpan={8} className="muted">Loading…</td></tr>}
            {rows && list.length === 0 && <tr><td colSpan={8} className="muted">Nothing matches that.</td></tr>}
            {list.map(r => (
              <tr key={r.email}>
                <td className="mono small muted">{r.serial_no ?? '—'}</td>
                <td className="mono small">{r.email}</td>
                <td>
                  <select value={String(r.batch_id ?? '')} onChange={e => move(r.email, e.target.value)}
                          style={{ width: 'auto', padding: '2px 6px', fontSize: 12 }}>
                    {batches.map(b => <option key={b.id} value={String(b.id)}>{b.name}</option>)}
                  </select>
                </td>
                <td>{r.claimed_by
                  ? <span className="badge submitted">registered</span>
                  : <span className="badge">waiting</span>}</td>
                <td>{r.registered_name || r.full_name || <span className="muted">—</span>}</td>
                <td className="mono">{r.claimed_by || <span className="muted">{r.roll_hint || '—'}</span>}</td>
                <td>{r.has_id
                  ? <button className="sm ghost" onClick={() => setViewing(r.claimed_by)}>View</button>
                  : <span className="muted small">—</span>}</td>
                <td>{!r.claimed_by && <button className="sm ghost" onClick={() => remove(r.email)}>Remove</button>}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {viewing && <IdViewer token={token} roll={viewing} onClose={() => setViewing(null)} />}
    </>
  )
}
