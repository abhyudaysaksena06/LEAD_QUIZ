export const fmtTime = iso =>
  iso ? new Date(iso).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' }) : '—'

export const fmtLeft = ms => {
  if (ms == null) return '—'
  if (ms <= 0) return '0:00'
  const s = Math.floor(ms / 1000)
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}

export const STATUS_LABEL = {
  not_started: 'Not started',
  in_progress: 'In progress',
  submitted: 'Submitted',
  blocked: 'Blocked',
  paused: 'Paused',
  banned: 'Banned',
}

export const REASON_LABEL = {
  MANUAL: 'Submitted by student',
  TIME_UP: 'Time up',
  FLAG_LIMIT: 'Violation limit',
  ADMIN: 'Force-submitted by admin',
  BANNED: 'Banned by a proctor',
}

export function StatusBadge({ status }) {
  return <span className={`badge ${status}`}>{STATUS_LABEL[status] || status}</span>
}
