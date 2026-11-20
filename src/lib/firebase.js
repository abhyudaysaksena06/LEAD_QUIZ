// Google sign-in via Firebase Auth (optional).
//
// The browser only obtains a Google-verified ID token here. It is sent once to /api/google-login,
// which checks Google's signature, audience, issuer and expiry on the server and then opens a
// portal session. Supabase itself is never asked to trust Firebase tokens, so this does not
// change sign-in for anything else in the same Supabase project.
//
// Without the VITE_FIREBASE_* variables the Google button is simply hidden.

const cfg = {
  apiKey: import.meta.env.VITE_FIREBASE_API_KEY,
  authDomain: import.meta.env.VITE_FIREBASE_AUTH_DOMAIN,
  projectId: import.meta.env.VITE_FIREBASE_PROJECT_ID,
  appId: import.meta.env.VITE_FIREBASE_APP_ID,
}

export const firebaseConfigured = Boolean(cfg.apiKey && cfg.projectId)

let ready = null
// Loaded on demand, so the Firebase SDK is downloaded only when someone presses the button.
function auth() {
  if (!firebaseConfigured) return Promise.resolve(null)
  if (!ready) {
    ready = (async () => {
      const { initializeApp, getApps } = await import('firebase/app')
      const { getAuth, inMemoryPersistence, setPersistence } = await import('firebase/auth')
      const app = getApps().length ? getApps()[0] : initializeApp(cfg)
      const a = getAuth(app)
      // the portal keeps its own session; Firebase only needs to live for the popup
      try { await setPersistence(a, inMemoryPersistence) } catch { /* ignore */ }
      return a
    })()
  }
  return ready
}

/** Opens Google's account chooser and returns a fresh ID token for the chosen account. */
export async function googleIdToken() {
  const a = await auth()
  if (!a) throw new Error('Google sign-in is not set up on this site.')
  const { GoogleAuthProvider, signInWithPopup, signOut } = await import('firebase/auth')
  const provider = new GoogleAuthProvider()
  provider.setCustomParameters({ prompt: 'select_account' })   // never silently reuse an account
  const res = await signInWithPopup(a, provider)
  const token = await res.user.getIdToken(true)
  try { await signOut(a) } catch { /* the token is all we need */ }
  return token
}
