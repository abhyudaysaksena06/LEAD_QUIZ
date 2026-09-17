import { useEffect, useState } from 'react'
import { rpc } from '../lib/api'

export const HELPLINE = '9166220353'

let cached = null
/** The display settings the instructions quote (questions, minutes, limits). Readable before sign-in. */
export function useExamInfo(initial) {
  const [info, setInfo] = useState(initial || cached)
  useEffect(() => {
    if (initial || cached) return
    let alive = true
    rpc('exam_info', {}).then(d => { cached = d; if (alive) setInfo(d) }).catch(() => {})
    return () => { alive = false }
  }, [initial])
  return initial || info
}

/** The exam rules. One copy, shown on the sign-in pages and on the start screen. */
export default function Instructions({ cfg, minutes }) {
  const c = cfg || {}
  const mins = minutes ?? c.duration_minutes ?? 20
  const mcq = c.mcq_count ?? 17
  const coding = c.coding_count ?? 3
  const flags = c.max_flags ?? 3
  return (
    <>
      <div className="brand-mark">{c.exam_title || 'LEAD Quiz'}</div>
      <h1>Instructions</h1>
      <p className="muted">Read these before you begin. They apply from the moment you press Start.</p>
      <ul className="rules">
        <li><b>Sign in with your official Thapar email</b> (your @thapar.edu Google account).</li>
        <li><b>Use a laptop</b> (preferably).</li>
        <li><b>{mcq + coding} questions</b>: {mcq} multiple choice
          {coding > 0 && <> and {coding} coding</>}.</li>
        <li><b>There is no negative marking.</b> A wrong answer costs you nothing, so never leave a
          multiple-choice question blank — answer every one.</li>
        {coding > 0 && (
          <li>The <b>{coding} coding questions are optional and carry no marks</b>. They are
            read by the panel and given written remarks, so attempt them if you have time — they can
            only help you. Answer in Python, JavaScript, C, C++ or Java; Python and JavaScript run in
            the editor, the rest are saved for the examiners to read.</li>
        )}
        <li><b>Your own {mins}-minute timer</b> starts when you press Start.
          It counts only while you are connected — if your internet or power fails, the clock stops until you are back.
          It cannot run past the end of your round.</li>
        <li>The test runs in <b>fullscreen</b>. These count as a violation:
          <ul className="sub-rules">
            <li>Leaving fullscreen, including by holding <b>Esc</b></li>
            <li>Switching to another tab, window or application</li>
            <li>Minimising the window or clicking away from the test</li>
            <li>Pressing <b>Print Screen</b> or trying to take a screenshot</li>
            <li>Pasting anything into the editor from outside the test</li>
            <li>Opening developer tools</li>
          </ul>
        </li>
        <li><b>{flags} violations</b> and your test is submitted automatically. Your answers
          up to that point are kept and marked.</li>
        {c.require_camera !== false && <li><b>Your camera must stay on</b> and is monitored during the test. Keep your face visible, sit alone, and keep your phone out of sight.</li>}
        {c.require_mic !== false && <li><b>Microphone access is required</b> for the duration of the test. Your browser will ask for permission when you press Start.</li>}
        <li>Answers save automatically. Don’t refresh or close the browser.</li>
        <li>Problem during the test? Use the <b>💬 Help</b> button to message a proctor — that is the
          fastest route and it reaches whoever is free. If your issue is serious and is
          <b> not resolved on chat</b>, call <b><a href={`tel:+91${HELPLINE}`}>{HELPLINE}</a></b>.</li>
      </ul>
    </>
  )
}

/** Instructions on the left, whatever the student needs to do on the right. */
export function SplitPage({ cfg, minutes, children }) {
  return (
    <div className="split-page">
      <section className="split-left card">
        <Instructions cfg={cfg} minutes={minutes} />
      </section>
      <aside className="split-right">{children}</aside>
    </div>
  )
}
