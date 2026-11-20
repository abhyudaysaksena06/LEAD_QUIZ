import { createClient } from '@supabase/supabase-js'
import { firebaseConfigured, firebaseIdToken } from './firebase'

const url = import.meta.env.VITE_SUPABASE_URL
const key = import.meta.env.VITE_SUPABASE_ANON_KEY

export const configured = Boolean(url && key)

// With Firebase present, every request carries the Firebase ID token so Postgres can
// read the verified email. Returning null falls back to the anon key.
export const supabase = configured
  ? createClient(url, key, firebaseConfigured
      ? { accessToken: async () => (await firebaseIdToken()) ?? null }
      : { auth: { persistSession: false } })
  : null

const FRIENDLY = {
  INVALID_CREDENTIALS: 'Incorrect username or password.',
  ADMIN_SESSION_INVALID: 'Admin session expired. Please sign in again.',
  TOO_MANY_ATTEMPTS: 'Too many failed sign-in attempts. Wait 10 minutes and try again.',
  NOT_SIGNED_IN: 'Google sign-in did not complete. Please try again.',
  EMAIL_NOT_VERIFIED: 'This Google account has no verified email address.',
  SCREENING_CLOSED: 'The screening round is not open right now.',
  SCREENING_NOT_REGISTERED: 'Register your team first.',
  SCREENING_NOT_STARTED: 'Press Start first.',
  SCREENING_ALREADY_STARTED: 'Your sprint has already started, so the team name and track can no longer be changed.',
  SCREENING_ALREADY_SUBMITTED: 'Your response has already been submitted.',
  SCREENING_TIME_UP: 'Time is up. Your response was submitted with everything saved before the deadline.',
  TEAM_NAME_INVALID: 'Team name must be 2 to 60 characters.',
  TEAM_NAME_TAKEN: 'Another team has already registered that name. Pick a different one.',
  TRACK_INVALID: 'Choose one of the three tracks.',
}

export class ApiError extends Error {
  constructor(code, message) {
    super(message)
    this.code = code
  }
}

export async function rpc(fn, args = {}) {
  if (!supabase) throw new ApiError('NOT_CONFIGURED', 'Supabase is not configured (.env).')
  const { data, error } = await supabase.rpc(fn, args)
  if (error) {
    // longest match wins: ADMIN_SESSION_INVALID must not be mistaken for SESSION_INVALID
    const code = Object.keys(FRIENDLY)
      .filter(k => error.message?.includes(k))
      .sort((a, b) => b.length - a.length)[0] || 'ERROR'
    throw new ApiError(code, FRIENDLY[code] || error.message || 'Something went wrong.')
  }
  // Some functions report failure in their result rather than raising, because a raised
  // error would roll back what they recorded (throttle counters, session revokes).
  if (data && data.ok === false && data.code) {
    throw new ApiError(data.code, FRIENDLY[data.code] || data.code)
  }
  return data
}

// ---- session storage (localStorage so a crash/reload can resume) ----
export const store = {
  get: k => { try { return JSON.parse(localStorage.getItem(k)) } catch { return null } },
  set: (k, v) => { try { localStorage.setItem(k, JSON.stringify(v)) } catch { /* ignore */ } },
  del: k => { try { localStorage.removeItem(k) } catch { /* ignore */ } },
}
