import { useCallback, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { rpc, store } from '../lib/api'
import ScreeningResponses from '../components/ScreeningAdmin'

/** Admin: every team's registration and response, settings, and the CSV download. */
export default function ScreeningAdmin() {
  const nav = useNavigate()
  const admin = store.get('admin')
  const token = admin?.token

  const signOut = useCallback(async (callServer = true) => {
    if (callServer) { try { await rpc('admin_logout', { p_token: token }) } catch { /* ignore */ } }
    store.del('admin')
    nav('/admin/login', { replace: true })
  }, [token, nav])

  useEffect(() => { if (!token) nav('/admin/login', { replace: true }) }, [token, nav])
  if (!token) return null

  return (
    <div className="admin">
      <header className="admin-top">
        <b>PRIMUS 2026 · Screening admin</b>
        <span className="spacer" />
        <span className="small">{admin?.display_name || admin?.username}</span>
        <button className="ghost sm" onClick={() => signOut()}>Sign out</button>
      </header>
      <div />
      <main className="admin-main">
        <ScreeningResponses token={token} onSessionInvalid={() => signOut(false)} />
      </main>
    </div>
  )
}
