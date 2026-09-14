import { useCallback, useEffect, useRef, useState } from 'react'

const fmtTime = iso => new Date(iso).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })

/**
 * Shared chat thread used by both the student panel and the admin inbox.
 * load(): Promise<messages[]>, send(body): Promise, me: 'student' | 'admin'
 */
export default function ChatBox({ load, send, me, pollMs = 4000, placeholder = 'Type a message…' }) {
  const [messages, setMessages] = useState([])
  const [draft, setDraft] = useState('')
  const [error, setError] = useState('')
  const [sending, setSending] = useState(false)
  const logRef = useRef(null)
  const lastCount = useRef(0)

  const refresh = useCallback(async () => {
    try { setMessages(await load()); setError('') }
    catch (e) { setError(e.message) }
  }, [load])

  useEffect(() => {
    refresh()
    const t = setInterval(refresh, pollMs)
    return () => clearInterval(t)
  }, [refresh, pollMs])

  useEffect(() => {
    if (messages.length !== lastCount.current && logRef.current) {
      logRef.current.scrollTop = logRef.current.scrollHeight
    }
    lastCount.current = messages.length
  }, [messages])

  async function submit(e) {
    e?.preventDefault()
    const body = draft.trim()
    if (!body) return
    setSending(true)
    try { await send(body); setDraft(''); await refresh() }
    catch (err) { setError(err.message) }
    finally { setSending(false) }
  }

  return (
    <>
      <div className="chat-log" ref={logRef}>
        {messages.length === 0 && <p className="muted small" style={{ textAlign: 'center', marginTop: 20 }}>No messages yet.</p>}
        {messages.map(m => (
          <div key={m.id} className={`bubble ${m.sender === me ? 'mine' : 'theirs'}`}>
            {m.body}
            <span className="meta">{m.sender === me ? 'You' : m.sender_name} · {fmtTime(m.created_at)}</span>
          </div>
        ))}
      </div>
      {error && <div className="error" style={{ margin: '0 10px' }}>{error}</div>}
      <form className="chat-input" onSubmit={submit}>
        <textarea value={draft} onChange={e => setDraft(e.target.value)} placeholder={placeholder}
                  onKeyDown={e => { if (e.key === 'Enter' && !e.shiftKey) submit(e) }} maxLength={2000} />
        <button disabled={sending || !draft.trim()}>Send</button>
      </form>
    </>
  )
}
