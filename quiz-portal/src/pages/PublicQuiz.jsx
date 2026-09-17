import { useState } from 'react'
import { useNavigate, Link } from 'react-router-dom'
import { rpc, store } from '../lib/api'
import { firebaseConfigured, signInWithGoogle, firebaseSignOut } from '../lib/firebase'
import { deviceId } from '../lib/device'
import Register from './Register'
import { SplitPage, useExamInfo } from '../components/Instructions'

/** The open quiz. No registration list: any Google account whose address contains
 *  "be26" or "btech26" may sign up. The server enforces the rule, not this page. */
export default function PublicQuiz() {
  const nav = useNavigate()
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const [reg, setReg] = useState(null)
  const info = useExamInfo()
  const [showPassword, setShowPassword] = useState(false)
  const [roll, setRoll] = useState('')
  const [password, setPassword] = useState('')

  async function passwordLogin(e) {
    e.preventDefault()
    setError(''); setBusy(true)
    try {
      enter(await rpc('student_login', { p_roll: roll.trim(), p_password: password, p_device: deviceId() }))
    } catch (err) { setError(err.message) }
    finally { setBusy(false) }
  }

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
    <SplitPage cfg={info}>
      <Register info={reg} mode="public"
                onDone={() => { store.set('entry', 'public'); nav('/exam') }}
                onCancel={() => setReg(null)} />
    </SplitPage>
  )

  return (
    <SplitPage cfg={info}>
      <div className="card narrow">
        <div className="brand-mark">LEAD Quiz</div>
        <h1>Open quiz</h1>
        <p className="muted">
          Sign in with your official <b>@thapar.edu</b> Google account. First-year addresses containing
          {' '}<b>be26</b> or <b>btech26</b> can start as soon as the quiz opens; any other Thapar address
          can register and will be able to start once an admin approves it.
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

        {!showPassword ? (
          <button type="button" className="ghost sm" style={{ width: '100%', marginTop: 12 }}
                  onClick={() => setShowPassword(true)}>
            Sign in with roll number and password
          </button>
        ) : (
          <form onSubmit={passwordLogin} style={{ marginTop: 12 }}>
            <label htmlFor="proll">Roll number</label>
            <input id="proll" value={roll} onChange={e => setRoll(e.target.value)} autoComplete="username" required />
            <label htmlFor="ppw">Password</label>
            <input id="ppw" type="password" value={password} onChange={e => setPassword(e.target.value)}
                   autoComplete="current-password" required />
            <button style={{ width: '100%', marginTop: 12 }} disabled={busy}>{busy ? 'Signing in…' : 'Sign in'}</button>
          </form>
        )}

        <p className="small muted" style={{ marginTop: 16 }}>
          First time here? After signing in you’ll be asked for your name and roll number once.
          Your camera and microphone are required during the quiz.
        </p>
        <p className="small muted" style={{ textAlign: 'center' }}>
          Selected for the LEAD recruitment round? <Link to="/recruitment">Use the recruitment page</Link>
        </p>
      </div>
    </SplitPage>
  )
}
