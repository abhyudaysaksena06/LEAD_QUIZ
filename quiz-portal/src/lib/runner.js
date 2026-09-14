// In-browser code execution for the coding terminal.
// Python runs on Pyodide (WebAssembly), JavaScript in a sandboxed Web Worker.
// Both run on the student's machine, isolated from the exam page, with a hard timeout.

export const LANGUAGES = [
  { id: 'python', label: 'Python 3', runnable: true },
  { id: 'javascript', label: 'JavaScript', runnable: true },
  { id: 'c', label: 'C', runnable: false },
  { id: 'cpp', label: 'C++', runnable: false },
  { id: 'java', label: 'Java', runnable: false },
]

const PY_TIMEOUT_MS = 6000
const JS_TIMEOUT_MS = 3000

const PY_WORKER = `
importScripts('https://cdn.jsdelivr.net/pyodide/v0.26.4/full/pyodide.js');
let py = null;
const ready = loadPyodide().then(p => { py = p; postMessage({ type: 'ready' }); })
  .catch(e => postMessage({ type: 'loaderror', message: String(e) }));
onmessage = async (e) => {
  await ready;
  const { code, stdin } = e.data;
  const out = [];
  const lines = (stdin || '').split('\\n'); let li = 0;
  py.setStdin({ stdin: () => (li < lines.length ? lines[li++] : undefined) });
  py.setStdout({ batched: s => out.push({ err: false, text: s }) });
  py.setStderr({ batched: s => out.push({ err: true, text: s }) });
  postMessage({ type: 'started' });
  try {
    const ns = py.globals.get('dict')();
    await py.runPythonAsync(code, { globals: ns });
    ns.destroy();
  } catch (x) {
    // trim Pyodide's internal frames: keep from the user's code onward
    const msg = String(x && x.message || x);
    const i = msg.indexOf('File "<exec>"');
    out.push({ err: true, text: i >= 0 ? 'Traceback (most recent call last):\\n  ' + msg.slice(i) : msg });
  }
  postMessage({ type: 'done', lines: out });
};`

const JS_WORKER = `
onmessage = (e) => {
  const out = [];
  const fmt = a => a.map(x => typeof x === 'string' ? x : (() => { try { return JSON.stringify(x) } catch { return String(x) } })()).join(' ');
  const lines = (e.data.stdin || '').split('\\n'); let li = 0;
  const input = () => (li < lines.length ? lines[li++] : '');
  const con = {
    log: (...a) => out.push({ err: false, text: fmt(a) }),
    info: (...a) => out.push({ err: false, text: fmt(a) }),
    warn: (...a) => out.push({ err: true, text: fmt(a) }),
    error: (...a) => out.push({ err: true, text: fmt(a) }),
  };
  try { new Function('console', 'input', 'prompt', 'readline', e.data.code)(con, input, input, input); }
  catch (x) { out.push({ err: true, text: String(x && x.stack || x) }); }
  postMessage({ type: 'done', lines: out });
};`

const blobWorker = src => new Worker(URL.createObjectURL(new Blob([src], { type: 'text/javascript' })))

let py = null // { worker, ready: Promise }

function getPython() {
  if (py) return py
  const worker = blobWorker(PY_WORKER)
  const ready = new Promise((resolve, reject) => {
    const h = e => {
      if (e.data.type === 'ready') { worker.removeEventListener('message', h); resolve() }
      if (e.data.type === 'loaderror') { worker.removeEventListener('message', h); reject(new Error(e.data.message)) }
    }
    worker.addEventListener('message', h)
    worker.addEventListener('error', () => reject(new Error('Could not load Python. Check your connection.')))
  })
  py = { worker, ready }
  ready.catch(() => { worker.terminate(); py = null })
  return py
}

function runPython(code, stdin, onStatus) {
  const p = getPython()
  onStatus?.('Loading Python… (first run takes a few seconds)')
  return p.ready.then(() => new Promise(resolve => {
    const t0 = performance.now()
    let timer
    const h = e => {
      if (e.data.type === 'started') {
        onStatus?.('Running…')
        timer = setTimeout(() => {
          p.worker.removeEventListener('message', h)
          p.worker.terminate(); py = null        // next run reloads a fresh interpreter
          resolve({ lines: [], timedOut: true, ms: PY_TIMEOUT_MS })
        }, PY_TIMEOUT_MS)
      }
      if (e.data.type === 'done') {
        clearTimeout(timer)
        p.worker.removeEventListener('message', h)
        resolve({ lines: e.data.lines, timedOut: false, ms: Math.round(performance.now() - t0) })
      }
    }
    p.worker.addEventListener('message', h)
    p.worker.postMessage({ code, stdin })
  }))
}

function runJavaScript(code, stdin, onStatus) {
  onStatus?.('Running…')
  return new Promise(resolve => {
    const worker = blobWorker(JS_WORKER)
    const t0 = performance.now()
    const timer = setTimeout(() => {
      worker.terminate()
      resolve({ lines: [], timedOut: true, ms: JS_TIMEOUT_MS })
    }, JS_TIMEOUT_MS)
    worker.onmessage = e => {
      clearTimeout(timer); worker.terminate()
      resolve({ lines: e.data.lines, timedOut: false, ms: Math.round(performance.now() - t0) })
    }
  })
}

// Output comparison: ignore trailing spaces on each line, trailing blank lines,
// and \r\n vs \n. Everything else must match exactly.
export function normalizeOutput(s) {
  return String(s ?? '')
    .replace(/\r\n/g, '\n')
    .split('\n').map(l => l.replace(/\s+$/, '')).join('\n')
    .replace(/\n+$/, '')
}

export const stdoutOf = result => result.lines.filter(l => !l.err).map(l => l.text).join('\n')
export const stderrOf = result => result.lines.filter(l => l.err).map(l => l.text).join('\n')

/** Run one program against many test cases. Used by students (sample tests)
 *  and by admins when grading (all tests, re-run on the admin's machine). */
export async function runTests(language, code, tests, onProgress) {
  const results = []
  for (let i = 0; i < tests.length; i++) {
    const t = tests[i]
    onProgress?.(i + 1, tests.length)
    const r = await runCode(language, code, t.stdin ?? '', () => {})
    const actual = stdoutOf(r)
    results.push({
      ...t,
      actual,
      error: stderrOf(r) || null,
      timedOut: r.timedOut,
      passed: !r.timedOut && normalizeOutput(actual) === normalizeOutput(t.expected_output),
    })
  }
  return results
}

export async function runCode(language, code, stdin, onStatus) {
  if (language === 'python') return runPython(code, stdin, onStatus)
  if (language === 'javascript') return runJavaScript(code, stdin, onStatus)
  return {
    lines: [{ err: false, text: `Running ${language.toUpperCase()} is not available in the browser.\nYour code is saved and will be evaluated by the examiners.` }],
    timedOut: false, ms: 0,
  }
}
