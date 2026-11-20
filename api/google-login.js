// POST /api/google-login  { idToken: <Firebase ID token from Google sign-in> }
//
// Verifies the token on the server (Google's signing keys, this Firebase project as audience
// and issuer, not expired, email verified), then asks the database to open a team-leader
// session for that email. The database only accepts the request with SCREENING_SERVER_SECRET,
// which exists only here, so a browser cannot claim someone else's Google address.
import { createClient } from '@supabase/supabase-js'
import { createRemoteJWKSet, jwtVerify } from 'jose'

const JWKS = createRemoteJWKSet(new URL(
  'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com'))

function fail(res, status, code, message) {
  res.status(status).json({ ok: false, code, message })
}

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store')
  if (req.method !== 'POST') { res.setHeader('Allow', 'POST'); return fail(res, 405, 'METHOD', 'POST only.') }

  const projectId = process.env.FIREBASE_PROJECT_ID || process.env.VITE_FIREBASE_PROJECT_ID
  const secret = process.env.SCREENING_SERVER_SECRET
  const url = process.env.SUPABASE_URL || process.env.VITE_SUPABASE_URL
  const anon = process.env.SUPABASE_ANON_KEY || process.env.VITE_SUPABASE_ANON_KEY
  if (!projectId || !secret || !url || !anon) {
    return fail(res, 503, 'GOOGLE_NOT_CONFIGURED', 'Google sign-in is not set up on this site. Use email and password.')
  }

  const body = typeof req.body === 'string' ? (() => { try { return JSON.parse(req.body) } catch { return {} } })() : (req.body || {})
  const idToken = String(body.idToken || '')
  if (!idToken || idToken.length > 4096) return fail(res, 400, 'BAD_REQUEST', 'idToken is required.')

  let claims
  try {
    ({ payload: claims } = await jwtVerify(idToken, JWKS, {
      issuer: `https://securetoken.google.com/${projectId}`,
      audience: projectId,
      algorithms: ['RS256'],
    }))
  } catch {
    return fail(res, 401, 'GOOGLE_TOKEN_INVALID', 'Google sign-in could not be verified. Please try again.')
  }
  if (!claims.sub || !claims.email) return fail(res, 401, 'GOOGLE_TOKEN_INVALID', 'Google did not return an email address.')
  if (claims.email_verified !== true) return fail(res, 403, 'EMAIL_NOT_VERIFIED', 'This Google account has no verified email address.')

  const db = createClient(url, anon, { auth: { persistSession: false } })
  const { data, error } = await db.rpc('screening_login_federated', {
    p_secret: secret, p_email: claims.email, p_provider: claims.firebase?.sign_in_provider || 'google',
  })
  if (error) {
    const denied = (error.message || '').includes('FEDERATION_DENIED')
    return fail(res, denied ? 503 : 500, denied ? 'GOOGLE_NOT_CONFIGURED' : 'DB_ERROR',
                denied ? 'Google sign-in is not set up on this site. Use email and password.' : 'Could not sign in. Please try again.')
  }
  if (!data?.ok) return fail(res, 400, data?.code || 'ERROR', 'Could not sign in with this account.')
  return res.status(200).json({ ok: true, token: data.token, email: data.email })
}
