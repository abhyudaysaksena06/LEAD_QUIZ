import { useState } from 'react'
import { useNavigate, Link } from 'react-router-dom'
import { rpc, store } from '../lib/api'
import { firebaseConfigured, signInWithGoogle, firebaseSignOut } from '../lib/firebase'
import { deviceId } from '../lib/device'
import Register from './Register'

/** The open quiz. No registration list: any Google account whose address contains
 *  "be26" or "btech26" may sign up. The server enforces the rule, not this page. */
export default function PublicQuiz() {
  const nav = useNavigate()
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const [reg, setReg] = useState(null)

  function enter(session) {
    store.set('entry', 'public')          // so sign-out returns here, not to the recruitment page
    store.set('student', session)
    nav('/exam')
  }

  async function google() {
    setError(''); setBusy(true)
    try {
      await signInWithGoogle()
      const r = await rpc('public_quiz_login_google', { p_device: deviceId() })
      if (r.needs_registration) { setReg(r); return }
      enter(r)
    } catch (err) {
      await firebaseSignOut()
      const m = err?.message || ''
      setError(m.includes('popup-closed') || m.includes('cancelled') ? '' : (m || 'Google sign-in failed.'))
    } finally {
      setBusy(false)
    }
  }

  if (reg) return (
    <div className="center-page">
      <Register info={reg} mode="public"
                onDone={() => { store.set('entry', 'public'); nav('/exam') }}
                onCancel={() => setReg(null)} />
    </div>
  )

  return (
    <div className="center-page">
      <div className="card narrow">
        <div className="brand-mark">LEAD Quiz</div>
        <h1>Public quiz</h1>
        <p className="muted">
          Open to first-year students. Sign in with your Google account — your email address must
          contain <b>be26</b> or <b>btech26</b>.
        </p>

        {firebaseConfigured ? (
          <button type="button" onClick={google} disabled={busy}
                  style={{ width: '100%', padding: '12px 16px', fontSize: 15,
                           background: '#fff', color: '#16202b', borderColor: 'var(--line)' }}>
            {busy ? 'Signing in…' : 'Continue with Google'}
          </button>
        ) : (
          <div className="error">Google sign-in isn’t set up on this site yet.</div>
        )}

        {error && <div className="error">{error}</div>}

        <p className="small muted" style={{ marginTop: 16 }}>
          First time here? After signing in you’ll be asked for your name and roll number once.
          Your camera and microphone are required during the quiz.
        </p>
        <p className="small muted" style={{ textAlign: 'center' }}>
          Selected for the LEAD recruitment round? <Link to="/">Use the recruitment page</Link>
        </p>
      </div>
    </div>
  )
}
