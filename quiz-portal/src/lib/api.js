import { createClient } from '@supabase/supabase-js'
import { firebaseConfigured, firebaseIdToken } from './firebase'

const url = import.meta.env.VITE_SUPABASE_URL
const key = import.meta.env.VITE_SUPABASE_ANON_KEY

export const configured = Boolean(url && key)

// With Firebase present, every request carries the Firebase ID token so Postgres can
// read the verified email. Returning null falls back to the anon key (password login).
export const supabase = configured
  ? createClient(url, key, firebaseConfigured
      ? { accessToken: async () => (await firebaseIdToken()) ?? null }
      : { auth: { persistSession: false } })
  : null

const FRIENDLY = {
  INVALID_CREDENTIALS: 'Incorrect roll number or password.',
  SESSION_INVALID: 'Your session has ended. Please sign in again.',
  ADMIN_SESSION_INVALID: 'Admin session expired. Please sign in again.',
  EXAM_CLOSED: 'The exam is not open yet.',
  BATCH_CLOSED: 'Your batch has not been started yet. Wait for the proctor.',
  NO_BATCH: 'You have not been assigned to a batch. Contact a proctor.',
  BATCH_EXISTS: 'A batch with that name already exists.',
  BATCH_NOT_EMPTY: 'Move the students out of this batch before deleting it.',
  LAST_BATCH: 'You cannot delete the only batch.',
  NO_SUCH_BATCH: 'That batch no longer exists.',
  EMAIL_NOT_REGISTERED: 'This Google account is not on the registration list. Use your roll number and password, or contact a proctor.',
  NOT_SIGNED_IN: 'Google sign-in did not complete. Please try again.',
  EMAIL_NOT_VERIFIED: 'This Google account has no verified email address.',
  BANNED: 'Your access to this test has been withdrawn. Please speak to the exam office.',
  SESSION_TAKEN: 'This account was opened in another browser, so this session was closed. Only one device may be signed in at a time.',
  TOO_MANY_ATTEMPTS: 'Too many failed sign-in attempts. Wait 10 minutes or ask a proctor.',
  CAPACITY_FULL: 'The test is at capacity right now. Wait a moment and press Start again.',
  ROUND_ENDED: 'Your round has finished. Contact a proctor if you were unable to start.',
  NOT_PAUSED: 'This student is not paused.',
  CONSENT_REQUIRED: 'You must accept the consent notice before starting.',
  ALREADY_REGISTERED: 'This account has already been registered.',
  ROLL_ALREADY_USED: 'That roll number is already registered by someone else. Check it, or contact a proctor.',
  ROLL_TOO_SHORT: 'Please enter your full roll number.',
  PUBLIC_EMAIL_NOT_ELIGIBLE: 'This quiz is only open to official @thapar.edu accounts containing be26 or btech26. Sign in with your Thapar email.',
  PUBLIC_QUIZ_CLOSED: 'Registration for the public quiz is closed.',
  USE_MAIN_PAGE: 'You are registered for the LEAD recruitment round. Please sign in on the recruitment page instead.',
  NO_SUCH_STUDENT: 'That student no longer exists.',
  NAME_REQUIRED: 'Please enter your full name.',
  ID_REQUIRED: 'Please attach a photo of your ID.',
  ALREADY_SUBMITTED: 'This test has already been submitted.',
  BLOCKED: 'This test has been blocked.',
  NO_QUESTIONS: 'No questions are available. Contact an admin.',
  NOT_BLOCKED: 'This student is not blocked.',
  NOT_IN_PROGRESS: 'This student has no test in progress.',
  NO_ATTEMPT: 'This student has not started the test.',
  MARKS_OUT_OF_RANGE: 'Marks must be between 0 and the question maximum.',
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
