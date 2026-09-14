import { useState } from 'react'
import { rpc, store } from '../lib/api'
import { compressImage } from '../lib/image'
import { firebaseSignOut } from '../lib/firebase'
import { deviceId } from '../lib/device'

/** Shown once, straight after Google sign-in, for an allowlisted student who
 *  hasn't registered yet. Collects name, roll number and a photo ID. */
export default function Register({ info, onDone, onCancel }) {
  const [name, setName] = useState(info.full_name || '')
  const [roll, setRoll] = useState(info.roll_hint || '')
  const [photo, setPhoto] = useState(null)      // { b64, dataUrl, bytes, mime }
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  async function pick(e) {
    const file = e.target.files?.[0]
    if (!file) return
    setError('')
    try { setPhoto(await compressImage(file)) }
    catch (err) { setPhoto(null); setError(err.message) }
  }

  async function submit(e) {
    e.preventDefault()
    if (!photo) { setError('Please attach a photo of your ID.'); return }
    setError(''); setBusy(true)
    try {
      const s = await rpc('student_register', {
        p_roll: roll.trim(), p_full_name: name.trim(),
        p_id_mime: photo.mime, p_id_b64: photo.b64, p_device: deviceId(),
      })
      store.set('student', s)
      onDone()
    } catch (err) {
      setError(err.message)
    } finally {
      setBusy(false)
    }
  }

  async function cancel() {
    await firebaseSignOut()
    onCancel()
  }

  return (
    <form className="card narrow" onSubmit={submit}>
      <div className="brand-mark">LEAD Quiz</div>
      <h1>Complete your registration</h1>
      <p className="muted">
        Signed in as <b>{info.email}</b>. This is a one-time step — do it now, well before
        the test starts.
      </p>

      <label htmlFor="nm">Full name</label>
      <input id="nm" value={name} onChange={e => setName(e.target.value)} autoFocus required
             placeholder="As written on your ID" />

      <label htmlFor="rl">Roll number</label>
      <input id="rl" value={roll} onChange={e => setRoll(e.target.value)} required
             placeholder="e.g. 1025030923" />

      <label htmlFor="id">Photo of your ID card</label>
      <input id="id" type="file" accept="image/*" capture="environment" onChange={pick} />
      <p className="small muted">College ID, Aadhaar, driving licence — anything with your name and photo.</p>

      {photo && (
        <div style={{ marginTop: 8 }}>
          <img src={photo.dataUrl} alt="Your ID preview"
               style={{ maxHeight: 160, borderRadius: 6, border: '1px solid var(--line)' }} />
          <div className="small muted">Ready to upload ({Math.round(photo.bytes / 1024)} KB)</div>
        </div>
      )}

      {error && <div className="error">{error}</div>}

      <button className="lg" style={{ width: '100%', marginTop: 18 }} disabled={busy}>
        {busy ? 'Saving…' : 'Finish registration'}
      </button>
      <p className="small muted" style={{ textAlign: 'center', marginTop: 12 }}>
        Wrong account? <button type="button" className="ghost sm" onClick={cancel}>Sign out</button>
      </p>
    </form>
  )
}
