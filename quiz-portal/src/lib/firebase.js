// Google sign-in via Firebase Auth.
//
// Supabase is configured to TRUST Firebase-issued JWTs (Authentication →
// Third-Party Auth → Firebase). The database reads the email out of that verified
// token, so the browser can never claim someone else's address.
//
// Firebase is optional: without the VITE_FIREBASE_* variables the app simply
// hides the Google button and uses roll number + password.

const cfg = {
  apiKey: import.meta.env.VITE_FIREBASE_API_KEY,
  authDomain: import.meta.env.VITE_FIREBASE_AUTH_DOMAIN,
  projectId: import.meta.env.VITE_FIREBASE_PROJECT_ID,
  appId: import.meta.env.VITE_FIREBASE_APP_ID,
}

export const firebaseConfigured = Boolean(cfg.apiKey && cfg.projectId)

let ready = null
// Loaded on demand so the Firebase SDK never enters the bundle for password-only setups.
function auth() {
  if (!firebaseConfigured) return Promise.resolve(null)
  if (!ready) {
    ready = (async () => {
      const { initializeApp, getApps } = await import('firebase/app')
      const { getAuth, onAuthStateChanged, setPersistence, browserLocalPersistence } = await import('firebase/auth')
      const app = getApps().length ? getApps()[0] : initializeApp(cfg)
      const a = getAuth(app)
      try { await setPersistence(a, browserLocalPersistence) } catch { /* private mode */ }
      // wait for a restored session before anyone asks for a token
      await new Promise(resolve => {
        const un = onAuthStateChanged(a, () => { un(); resolve() })
      })
      return a
    })()
  }
  return ready
}

export async function signInWithGoogle() {
  const a = await auth()
  if (!a) throw new Error('Google sign-in is not configured.')
  const { GoogleAuthProvider, signInWithPopup } = await import('firebase/auth')
  const provider = new GoogleAuthProvider()
  provider.setCustomParameters({ prompt: 'select_account' })   // never silently reuse an account
  const res = await signInWithPopup(a, provider)
  // force-refresh so a role claim added by a Cloud Function is present on the token
  await res.user.getIdToken(true)
  return res.user.email
}

export async function firebaseIdToken() {
  const a = await auth()
  return a?.currentUser ? a.currentUser.getIdToken() : null
}

export async function firebaseSignOut() {
  const a = await auth()
  if (!a) return
  const { signOut } = await import('firebase/auth')
  try { await signOut(a) } catch { /* ignore */ }
}
