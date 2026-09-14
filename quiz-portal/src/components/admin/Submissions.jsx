import { useState } from 'react'
import { rpc } from '../../lib/api'
import { StatusBadge, fmtTime } from './util'

function download(text, filename, type = 'text/csv') {
  const a = document.createElement('a')
  a.href = URL.createObjectURL(new Blob([text], { type }))
  a.download = filename
  a.click()
  setTimeout(() => URL.revokeObjectURL(a.href), 1000)
}

const csvOf = rows => {
  const cols = Object.keys(rows[0])
  const esc = v => (v == null ? '' : `"${String(v).replace(/"/g, '""')}"`)
  return [cols.join(','), ...rows.map(r => cols.map(c => esc(r[c])).join(','))].join('\n')
}

export default function Submissions({ token, students, onOpen, onChanged }) {
  const [busy, setBusy] = useState(false)
  const [progress, setProgress] = useState('')
  const [msg, setMsg] = useState('')

  const rows = students.filter(s => s.status !== 'not_started')
  const finished = rows.filter(s => s.status === 'submitted' || s.status === 'blocked')

  async function exportAnswers() {
    setBusy(true); setMsg('')
    try {
      const data = await rpc('admin_export_answers', { p_token: token })
      if (!data.length) { setMsg('No answers stored yet.'); return }
      download(csvOf(data), `lead-quiz-answers-${new Date().toISOString().slice(0, 16).replace(/[:T]/g, '-')}.csv`)
      setMsg(`Exported ${data.length} answer rows.`)
    } catch (e) { setMsg(e.message) }
    finally { setBusy(false) }
  }

  return (
    <>
      <div className="stats">
        <div className="stat"><b>{rows.length}</b><span>Attempts</span></div>
        <div className="stat"><b style={{ color: 'var(--ok)' }}>{finished.length}</b><span>Finished</span></div>
        <div className="stat"><b>{rows.filter(s => s.status === 'in_progress').length}</b><span>Still writing</span></div>
      </div>

      <div className="toolbar">
        <button onClick={exportAnswers} disabled={busy}>Export all answers (CSV)</button>
        {progress && <span className="small muted">{progress}</span>}
      </div>
      <p className="small muted" style={{ maxWidth: 760, marginTop: -4 }}>
        MCQs are graded automatically the moment a test is submitted. <b>Coding answers are stored as
        written text</b> and marked by you — open a student to read their code and enter marks. Students can
        run their code against sample tests while writing, but that never affects the score.
      </p>
      {msg && <div className="error" style={{ background: 'var(--brand-soft)', color: 'var(--brand-dark)' }}>{msg}</div>}

      <div className="table-wrap">
        <table>
          <thead><tr>
            <th>Roll no</th><th>Name</th><th>Batch</th><th>Status</th><th>Answered</th>
            <th>MCQ</th><th>Coding</th><th>Total</th><th>Submitted</th><th></th>
          </tr></thead>
          <tbody>
            {rows.length === 0 && <tr><td colSpan={10} className="muted">Nobody has started yet.</td></tr>}
            {rows.map(s => (
              <tr key={s.roll_no}>
                <td className="mono"><b>{s.roll_no}</b></td>
                <td>{s.full_name || <span className="muted">—</span>}</td>
                <td className="small">{s.batch_name || '—'}</td>
                <td><StatusBadge status={s.status} /></td>
                <td>{s.total_questions ? `${s.answered}/${s.total_questions}` : '—'}</td>
                <td>{s.mcq_score ?? <span className="muted">—</span>}</td>
                <td>{s.coding_score ?? <span className="muted">—</span>}</td>
                <td><b>{s.total_score ?? '—'}</b></td>
                <td className="small">{s.submitted_at ? fmtTime(s.submitted_at) : '—'}</td>
                <td><button className="sm ghost" onClick={() => onOpen(s.roll_no)}>View answers</button></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  )
}
