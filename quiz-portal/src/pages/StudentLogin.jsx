import { useState } from 'react'
import { useNavigate, Link } from 'react-router-dom'
import { rpc, store } from '../lib/api'
import { firebaseConfigured, signInWithGoogle, firebaseSignOut } from '../lib/firebase'
import { deviceId } from '../lib/device'
import Register from './Register'
import { SplitPage, useExamInfo } from '../components/Instructions'

function GoogleMark() {
  return (
    <svg width="18" height="18" viewBox="0 0 48 48" aria-hidden style={{ verticalAlign: '-3px', marginRight: 10 }}>
      <path fill="#4285F4" d="M45 24c0-1.6-.1-2.7-.4-3.9H24v7.1h12c-.2 1.8-1.5 4.6-4.4 6.5l6.8 5.3C42.3 35.3 45 30.1 45 24z" />
      <path fill="#34A853" d="M24 46c5.9 0 10.9-2 14.5-5.3l-6.8-5.3c-1.9 1.3-4.4 2.2-7.7 2.2-5.9 0-10.9-3.9-12.6-9.2l-7 5.4C7.9 41 15.4 46 24 46z" />
      <path fill="#FBBC05" d="M11.4 28.4c-.5-1.3-.7-2.8-.7-4.4s.3-3.1.7-4.4l-7-5.4C3.6 17 3 20.4 3 24s.6 7 2.4 9.8l6-5.4z" />
      <path fill="#EA4335" d="M24 10.6c4.2 0 7 1.8 8.6 3.3l6.3-6.1C35 4.3 29.9 2 24 2 15.4 2 7.9 7 5.4 14.2l7 5.4c1.7-5.3 6.7-9 11.6-9z" />
    </svg>
  )
}

export default function StudentLogin() {
  const nav = useNavigate()
  const [roll, setRoll] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const [reg, setReg] = useState(null)
  const [showPassword, setShowPassword] = useState(!firebaseConfigured)
  const info = useExamInfo()

  async function google() {
    setError(''); setBusy(true)
    try {
      await signInWithGoogle()
      const r = await rpc('student_login_google', { p_device: deviceId() })
      store.set('entry', 'main')
      if (r.needs_registration) { setReg(r); return }   // first time: collect name/roll/ID
      store.set('student', r)
      nav('/exam')
    } catch (err) {
      await firebaseSignOut()
      const m = err?.message || ''
      setError(m.includes('popup-closed') || m.includes('cancelled') ? '' : (m || 'Google sign-in failed.'))
    } finally {
      setBusy(false)
    }
  }

  async function submit(e) {
    e.preventDefault()
    setError(''); setBusy(true)
    try {
      store.set('entry', 'main')
      store.set('student', await rpc('student_login',
        { p_roll: roll.trim(), p_password: password, p_device: deviceId() }))
      nav('/exam')
    } catch (err) {
      setError(err.message)
    } finally {
      setBusy(false)
    }
  }

  if (reg) return (
    <SplitPage cfg={info}>
      <Register info={reg} onDone={() => nav('/exam')} onCancel={() => setReg(null)} />
    </SplitPage>
  )

  return (
    <SplitPage cfg={info}>
      <div className="card narrow">
        <div className="brand-mark">LEAD Quiz</div>
        <h1>Student sign in</h1>

        {firebaseConfigured ? (
          <>
            <p className="muted">Sign in with the Google account you registered with.</p>
            <button type="button" onClick={google} disabled={busy}
                    style={{ width: '100%', padding: '12px 16px', fontSize: 15,
                             background: '#fff', color: '#16202b', borderColor: 'var(--line)' }}>
              <GoogleMark />{busy ? 'Signing in…' : 'Continue with Google'}
            </button>
          </>
        ) : (
          <div className="error" style={{ background: 'var(--warn-soft)', color: 'var(--warn)' }}>
            Google sign-in isn’t set up yet. Add the <code>VITE_FIREBASE_*</code> values to <code>.env</code>.
            Until then, use your roll number and password.
          </div>
        )}

        {error && <div className="error">{error}</div>}

        {firebaseConfigured && (
          <div className="row" style={{ margin: '18px 0 14px' }}>
            <span style={{ flex: 1, borderTop: '1px solid var(--line)' }} />
            <span className="small muted">or</span>
            <span style={{ flex: 1, borderTop: '1px solid var(--line)' }} />
          </div>
        )}

        {!showPassword ? (
          <button type="button" className="ghost" style={{ width: '100%' }}
                  onClick={() => setShowPassword(true)}>
            Sign in with roll number and password
          </button>
        ) : (
          <form onSubmit={submit}>
            <label htmlFor="roll">Roll number</label>
            <input id="roll" inputMode="numeric" autoComplete="username" autoFocus={!firebaseConfigured}
                   value={roll} onChange={e => setRoll(e.target.value)} placeholder="e.g. 1025030923" required />

            <label htmlFor="pw">Password</label>
            <input id="pw" type="password" autoComplete="current-password"
                   value={password} onChange={e => setPassword(e.target.value)} required />

            <button style={{ width: '100%', marginTop: 16 }} disabled={busy}>
              {busy ? 'Signing in…' : 'Sign in'}
            </button>
          </form>
        )}

        <p className="small muted" style={{ marginTop: 16, textAlign: 'center' }}>
          Taking the open quiz? <Link to="/">Open quiz</Link> · Proctor? <Link to="/admin/login">Admin portal</Link>
        </p>
      </div>
    </SplitPage>
  )
}
