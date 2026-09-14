import { useState } from 'react'
import { useNavigate, Link } from 'react-router-dom'
import { rpc, store } from '../lib/api'

export default function AdminLogin() {
  const nav = useNavigate()
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  async function submit(e) {
    e.preventDefault()
    setError(''); setBusy(true)
    try {
      const s = await rpc('admin_login', { p_username: username.trim(), p_password: password })
      store.set('admin', s)
      nav('/admin')
    } catch (err) {
      setError(err.message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="center-page">
      <form className="card narrow" onSubmit={submit}>
        <div className="brand-mark">LEAD Quiz · Proctor</div>
        <h1>Admin sign in</h1>

        <label htmlFor="u">Username</label>
        <input id="u" autoComplete="username" autoFocus value={username}
               onChange={e => setUsername(e.target.value)} required />

        <label htmlFor="p">Password</label>
        <input id="p" type="password" autoComplete="current-password" value={password}
               onChange={e => setPassword(e.target.value)} required />

        {error && <div className="error">{error}</div>}

        <button className="lg" style={{ width: '100%', marginTop: 18 }} disabled={busy}>
          {busy ? 'Signing in…' : 'Sign in'}
        </button>
        <p className="small muted" style={{ marginTop: 14, textAlign: 'center' }}>
          <Link to="/">Back to student sign in</Link>
        </p>
      </form>
    </div>
  )
}
