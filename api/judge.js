// POST /api/judge  { token: <admin session token>, email: <team leader's email> }
//
// Runs the AI judge on one submitted response and stores the result. The Anthropic key
// (ANTHROPIC_API_KEY) exists only here, on the server. The admin's own session token is
// passed to the database for every step, so only a signed-in admin can trigger a judgement
// and the database decides what the judge may read.
import { createClient } from '@supabase/supabase-js'
import { judge, JudgeError } from './_judge.js'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

function fail(res, status, code, message) {
  res.status(status).json({ ok: false, code, message })
}

async function rpc(db, fn, args) {
  const { data, error } = await db.rpc(fn, args)
  if (error) {
    const m = error.message || ''
    const code = ['ADMIN_SESSION_INVALID', 'NOT_SUBMITTED', 'SCREENING_NOT_REGISTERED', 'ANSWERS_CHANGED', 'JUDGEMENT_INVALID']
      .find(c => m.includes(c)) || 'DB_ERROR'
    const status = code === 'ADMIN_SESSION_INVALID' ? 401 : code === 'DB_ERROR' ? 500 : 409
    throw Object.assign(new Error(m), { code, status })
  }
  return data
}

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store')
  if (req.method !== 'POST') { res.setHeader('Allow', 'POST'); return fail(res, 405, 'METHOD', 'POST only.') }

  const apiKey = process.env.ANTHROPIC_API_KEY
  const url = process.env.SUPABASE_URL || process.env.VITE_SUPABASE_URL
  const anon = process.env.SUPABASE_ANON_KEY || process.env.VITE_SUPABASE_ANON_KEY
  if (!apiKey) return fail(res, 503, 'JUDGE_NOT_CONFIGURED', 'The AI judge is not set up: add ANTHROPIC_API_KEY in Vercel → Settings → Environment Variables, then redeploy.')
  if (!url || !anon) return fail(res, 503, 'DB_NOT_CONFIGURED', 'Supabase URL / anon key are missing on the server.')

  const body = typeof req.body === 'string' ? (() => { try { return JSON.parse(req.body) } catch { return {} } })() : (req.body || {})
  const token = String(body.token || '')
  const email = String(body.email || '').trim().toLowerCase()
  if (!UUID.test(token) || !email || email.length > 254) return fail(res, 400, 'BAD_REQUEST', 'token and email are required.')

  const db = createClient(url, anon, { auth: { persistSession: false } })
  try {
    // 1. the anonymised response + rubric (checks the admin session)
    const input = await rpc(db, 'admin_screening_judge_input', { p_token: token, p_email: email })
    if (!input || !Array.isArray(input.prompts) || !Array.isArray(input.rubric)) {
      return fail(res, 500, 'DB_ERROR', 'The database returned no response to judge.')
    }
    // 2. grade it
    const { verdict, model, usage } = await judge(input, { apiKey })
    // 3. store it (rejected if the answers changed while grading)
    const saved = await rpc(db, 'admin_screening_save_judgement', {
      p_token: token, p_email: email, p_result: verdict,
      p_answers_hash: input.answers_hash, p_model: model, p_usage: usage,
    })
    if (!saved || saved.ok !== true) return fail(res, 500, 'DB_ERROR', 'The judgement could not be saved.')
    return res.status(200).json({ ok: true, ...saved, model, usage })
  } catch (e) {
    if (e instanceof JudgeError) return fail(res, e.status, e.code, e.message)
    return fail(res, e.status || 500, e.code || 'ERROR', e.message || 'Something went wrong.')
  }
}
