import { useEffect, useState } from 'react'
import { rpc } from '../../lib/api'

/** One student's camera, about a frame a second. A proctor watches one student at a time:
 *  opening another replaces this one. Nothing is recorded — closing it deletes the frame. */
export default function LiveView({ token, roll, name, onClose }) {
  const [frame, setFrame] = useState(null)      // { src, at }
  const [note, setNote] = useState('Connecting — the student’s camera starts within 10 seconds…')
  const [, tick] = useState(0)

  useEffect(() => {
    let alive = true
    let offset = 0
    setFrame(null)
    setNote('Connecting — the student’s camera starts within 10 seconds…')

    rpc('admin_watch_start', { p_token: token, p_roll: roll }).catch(e => alive && setNote(e.message))

    const poll = async () => {
      try {
        const r = await rpc('admin_watch_frame', { p_token: token, p_roll: roll })
        if (!alive) return
        if (!r.watching) {
          setNote(r.taken_by ? `${r.taken_by} is now watching this student.` : 'Live view ended.')
          return
        }
        offset = new Date(r.server_now) - Date.now()
        if (r.frame) {
          setFrame({ src: `data:${r.mime};base64,${r.frame}`, at: new Date(r.frame_at).getTime() - offset })
          setNote(r.status && r.status !== 'in_progress' ? `Test status: ${r.status}.` : '')
        }
      } catch (e) { if (alive) setNote(e.message) }
    }
    poll()
    const t = setInterval(poll, 1000)
    const c = setInterval(() => tick(x => x + 1), 1000)
    return () => {
      alive = false
      clearInterval(t); clearInterval(c)
      rpc('admin_watch_stop', { p_token: token }).catch(() => {})
    }
  }, [token, roll])

  const age = frame ? Math.max(0, Math.round((Date.now() - frame.at) / 1000)) : null
  const stale = age != null && age > 12

  return (
    <div className="live-view">
      <div className="row">
        <span className="live-dot" style={{ background: frame && !stale ? 'var(--bad)' : 'var(--line)' }} />
        <b className="mono">{roll}</b>
        <span className="small muted" style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{name}</span>
        <span className="spacer" />
        <button className="sm ghost" onClick={onClose}>Stop ✕</button>
      </div>
      <div className="live-frame">
        {frame
          ? <img src={frame.src} alt={`Live camera of ${roll}`} style={{ opacity: stale ? 0.45 : 1 }} />
          : <span className="small muted">No picture yet</span>}
      </div>
      <div className="small muted">
        {note || (stale ? `No new picture for ${age}s — the student may be offline.` : `Live · ${age}s ago · about 1 frame a second`)}
      </div>
    </div>
  )
}
