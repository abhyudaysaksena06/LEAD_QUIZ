import { useCallback, useEffect, useState } from 'react'
import { rpc } from '../../lib/api'
import { fmtTime } from './util'

const KIND = {
  PHONE_DETECTED: { label: 'Possible phone', colour: 'var(--bad)' },
  MULTIPLE_PEOPLE: { label: 'More than one person', colour: 'var(--bad)' },
  NO_PERSON: { label: 'Nobody in frame', colour: 'var(--warn)' },
}

function Item({ token, item, onDone }) {
  const [img, setImg] = useState(null)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  const k = KIND[item.kind] || { label: item.kind, colour: 'var(--muted)' }

  useEffect(() => {
    let alive = true
    rpc('admin_review_image', { p_token: token, p_id: item.id })
      .then(d => { if (alive) setImg(d.found ? d : null) })
      .catch(() => {})
    return () => { alive = false }
  }, [token, item.id])

  async function decide(approve) {
    if (approve) {
      const next = Number(item.flag_count ?? 0) + 1
      const warn = next >= Number(item.max_flags ?? 3)
        ? `\n\nThis is violation ${next} of ${item.max_flags} — approving will END their test and sign them out.`
        : `\n\nThis becomes violation ${next} of ${item.max_flags}.`
      if (!window.confirm(`Flag ${item.roll_no} for "${k.label}"?${warn}`)) return
    }
    setBusy(true); setErr('')
    try {
      const r = await rpc('admin_decide_detection', { p_token: token, p_id: item.id, p_approve: approve })
      onDone(approve && r.blocked
        ? `${item.roll_no} flagged — test ended (${r.flag_count}/${r.max_flags}).`
        : approve ? `${item.roll_no} flagged (${r.flag_count}/${r.max_flags}).`
        : `Dismissed — nothing recorded against ${item.roll_no}.`)
    } catch (e) { setErr(e.message); setBusy(false) }
  }

  return (
    <div className="section" style={{ borderLeft: `4px solid ${k.colour}` }}>
      <div className="row">
        <b className="mono">{item.roll_no}</b>
        <span className="muted small">{item.full_name}</span>
        <span className="badge" style={{ background: 'var(--warn-soft)', color: k.colour }}>{k.label}</span>
        <span className="spacer" />
        <span className="small muted">{fmtTime(item.created_at)}</span>
      </div>

      {img
        ? <img src={`data:${img.mime};base64,${img.image_b64}`} alt={`Snapshot of ${item.roll_no}`}
               style={{ width: '100%', borderRadius: 6, margin: '8px 0', background: '#000' }} />
        : <p className="muted small" style={{ margin: '8px 0' }}>Loading snapshot…</p>}

      <div className="small muted">
        {item.detail?.people?.length > 0 && <>people: {item.detail.people.join(', ')} · </>}
        {item.detail?.phones?.length > 0 && <>phone: {item.detail.phones.join(', ')} · </>}
        violations so far: {item.flag_count ?? 0}/{item.max_flags ?? 3}
      </div>

      {err && <div className="error">{err}</div>}

      <div className="row" style={{ marginTop: 10 }}>
        <button className="danger" disabled={busy} onClick={() => decide(true)}>Flag this student</button>
        <button className="ghost" disabled={busy} onClick={() => decide(false)}>Dismiss</button>
        <span className="spacer" />
        <span className="small muted">The picture is deleted either way.</span>
      </div>
    </div>
  )
}

export default function CameraReview({ token }) {
  const [items, setItems] = useState(null)
  const [msg, setMsg] = useState('')
  const [err, setErr] = useState('')

  const load = useCallback(async () => {
    try { setItems(await rpc('admin_review_queue', { p_token: token })); setErr('') }
    catch (e) { setErr(e.message) }
  }, [token])

  useEffect(() => {
    load()
    const t = setInterval(load, 5000)
    return () => clearInterval(t)
  }, [load])

  return (
    <>
      <p className="muted small" style={{ maxWidth: 780 }}>
        The camera detector never flags anyone by itself. When it sees a phone, more than one person,
        or an empty chair, it sends <b>one snapshot here</b> for you to judge. <b>Flag</b> records a
        violation against the student (three ends their test); <b>Dismiss</b> does nothing at all.
        Snapshots are deleted the moment you decide, and anything unreviewed is purged after 30 minutes —
        no images are ever stored against a student.
      </p>
      {err && <div className="error">{err}</div>}
      {msg && <div className="error" style={{ background: 'var(--brand-soft)', color: 'var(--brand-dark)' }}>{msg}</div>}

      {!items && <p className="muted">Loading…</p>}
      {items && items.length === 0 && (
        <div className="section"><p className="muted" style={{ margin: 0 }}>Nothing waiting for review.</p></div>
      )}

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(320px, 1fr))', gap: 14 }}>
        {(items || []).map(it => (
          <Item key={it.id} token={token} item={it}
                onDone={m => { setMsg(m); load() }} />
        ))}
      </div>
    </>
  )
}
