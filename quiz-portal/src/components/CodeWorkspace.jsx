import { useRef, useState } from 'react'
import { LANGUAGES, runCode, runTests } from '../lib/runner'

// Text copied *inside* the editor during this session. Pasting anything else is refused,
// so code can be moved around in the editor but not brought in from outside.
let internalClipboard = ''

function CodeEditor({ value, onChange, onBlockedPaste }) {
  const ta = useRef(null)
  const gutter = useRef(null)
  const lineCount = Math.max(1, value.split('\n').length)

  function replaceSelection(text, cursorOffset = text.length) {
    const el = ta.current
    const { selectionStart: s, selectionEnd: e } = el
    const next = value.slice(0, s) + text + value.slice(e)
    onChange(next)
    requestAnimationFrame(() => { el.selectionStart = el.selectionEnd = s + cursorOffset })
  }

  function onKeyDown(e) {
    if (e.key === 'Tab') {
      e.preventDefault()
      replaceSelection('    ')
    } else if (e.key === 'Enter') {
      e.preventDefault()
      const s = ta.current.selectionStart
      const lineStart = value.lastIndexOf('\n', s - 1) + 1
      const indent = value.slice(lineStart, s).match(/^\s*/)[0]
      const extra = /[:{([]\s*$/.test(value.slice(lineStart, s)) ? '    ' : ''
      replaceSelection('\n' + indent + extra)
    }
  }

  function remember() {
    const el = ta.current
    internalClipboard = value.slice(el.selectionStart, el.selectionEnd)
  }

  function onPaste(e) {
    const text = e.clipboardData.getData('text')
    if (!text || text !== internalClipboard) {
      e.preventDefault()
      onBlockedPaste?.()
    }
  }

  return (
    <div className="editor">
      <div className="gutter" ref={gutter}>
        {Array.from({ length: lineCount }, (_, i) => i + 1).join('\n')}
      </div>
      <textarea
        ref={ta}
        className="code-input"
        spellCheck={false}
        autoCapitalize="off"
        autoComplete="off"
        value={value}
        onChange={e => onChange(e.target.value)}
        onKeyDown={onKeyDown}
        onCopy={remember}
        onCut={remember}
        onPaste={onPaste}
        onDrop={e => e.preventDefault()}
        onScroll={e => { if (gutter.current) gutter.current.scrollTop = e.target.scrollTop }}
      />
    </div>
  )
}

export default function CodeWorkspace({ code, language, tests = [], onCodeChange, onLanguageChange, onBlockedPaste }) {
  const [stdin, setStdin] = useState('')
  const [output, setOutput] = useState(null)   // { lines, timedOut, ms }
  const [status, setStatus] = useState('')
  const [running, setRunning] = useState(false)
  const [sampleResults, setSampleResults] = useState(null)
  const lang = LANGUAGES.find(l => l.id === language) || LANGUAGES[0]

  async function runSamples() {
    setRunning(true); setSampleResults(null); setOutput(null)
    try {
      setStatus('Running sample tests…')
      setSampleResults(await runTests(lang.id, code, tests,
        (i, n) => setStatus(`Running sample test ${i} of ${n}…`)))
    } finally { setRunning(false); setStatus('') }
  }

  async function run() {
    setRunning(true); setOutput(null)
    try {
      setOutput(await runCode(lang.id, code, stdin, setStatus))
    } catch (err) {
      setOutput({ lines: [{ err: true, text: err.message }], timedOut: false, ms: 0 })
    } finally {
      setRunning(false); setStatus('')
    }
  }

  return (
    <div className="coding">
      <div className="code-toolbar">
        <select value={lang.id} onChange={e => onLanguageChange(e.target.value)} aria-label="Language">
          {LANGUAGES.map(l => <option key={l.id} value={l.id}>{l.label}{l.runnable ? '' : ' (save only)'}</option>)}
        </select>
        <span className="small muted">Your code saves automatically.</span>
        <span className="spacer" />
        {tests.length > 0 && lang.runnable && (
          <button className="sm ghost" onClick={runSamples} disabled={running}>Run sample tests</button>
        )}
        <button className="success sm" onClick={run} disabled={running}>
          {running ? 'Running…' : '▶ Run'}
        </button>
      </div>

      {sampleResults && (
        <div className="section" style={{ margin: 0, padding: 10 }}>
          <b className="small">Sample tests: {sampleResults.filter(r => r.passed).length} of {sampleResults.length} passed</b>
          <p className="small muted" style={{ margin: '4px 0 8px' }}>
            These are examples only — your answer is graded against additional hidden tests.
          </p>
          {sampleResults.map((r, i) => (
            <div key={i} className="ans" style={{ padding: '6px 0' }}>
              <div className="row small">
                <span style={{ color: r.passed ? 'var(--ok)' : 'var(--bad)', fontWeight: 700 }}>
                  {r.passed ? '✓ passed' : r.timedOut ? '✗ timed out' : '✗ failed'}
                </span>
                <span className="muted">input: {JSON.stringify(r.stdin)}</span>
              </div>
              {!r.passed && (
                <div className="row small" style={{ gap: 16, marginTop: 2 }}>
                  <span>expected <code>{r.expected_output}</code></span>
                  <span>got <code>{r.actual || '(nothing)'}</code></span>
                </div>
              )}
            </div>
          ))}
        </div>
      )}

      <CodeEditor value={code} onChange={onCodeChange} onBlockedPaste={onBlockedPaste} />

      <div className="terminal">
        <div className="term-head">
          <span>TERMINAL</span>
          <span className="spacer" />
          {status && <span>{status}</span>}
          {output && !status && <span>{output.timedOut ? 'timed out' : `finished in ${output.ms} ms`}</span>}
        </div>
        <pre>
          {!output && !running && <span style={{ color: '#5b6b7d' }}>Press Run to execute your code. Input below is fed to input().</span>}
          {output?.timedOut && <span className="stderr">Time limit exceeded — possible infinite loop.</span>}
          {output?.lines.map((l, i) => <span key={i} className={l.err ? 'stderr' : ''}>{l.text + '\n'}</span>)}
          {output && !output.timedOut && output.lines.length === 0 && <span style={{ color: '#5b6b7d' }}>(no output)</span>}
        </pre>
        <textarea className="code-input" placeholder="Program input (stdin) — one value per line"
                  value={stdin} onChange={e => setStdin(e.target.value)} spellCheck={false} />
      </div>
    </div>
  )
}
