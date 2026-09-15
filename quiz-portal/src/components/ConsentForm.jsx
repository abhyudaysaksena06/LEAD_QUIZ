import { useState } from 'react'

export const CONSENT_VERSION = 'v1.1'

/** Shown once, when the candidate presses Start. Acceptance is recorded in the
 *  database with a timestamp and this version string. */
export default function ConsentForm({ examTitle, roll, name, requireCamera, requireMic, maxFlags, minutes, onAgree, onCancel, busy }) {
  const [ticked, setTicked] = useState(false)

  return (
    <div className="overlay">
      <div className="card" style={{ maxWidth: 780, textAlign: 'left', maxHeight: '92vh', display: 'flex', flexDirection: 'column' }}>
        <div>
          <div className="brand-mark">{examTitle || 'LEAD Quiz'}</div>
          <h2 style={{ marginBottom: 2 }}>Candidate Consent and Examination Rules</h2>
          <p className="small muted" style={{ marginBottom: 12 }}>
            Version {CONSENT_VERSION} &nbsp;·&nbsp; {roll}{name ? ` · ${name}` : ''}
          </p>
        </div>

        <div style={{ overflowY: 'auto', paddingRight: 10, borderTop: '1px solid var(--line)',
                      borderBottom: '1px solid var(--line)', padding: '12px 10px 12px 0', fontSize: 13.5, lineHeight: 1.6 }}>
          <h3 style={{ fontSize: 13.5 }}>1. Identity</h3>
          <p>1.1 The name, roll number and photograph of identification submitted at registration are
            retained for the purpose of verifying the candidate's identity.</p>

          <h3 style={{ fontSize: 13.5 }}>2. Monitoring during the examination</h3>
          <p>2.1 The examination is conducted in full-screen mode. Exiting full-screen, switching to another
            window or application, and loss of window focus are recorded automatically.</p>
          <p>2.2 {maxFlags ?? 3} recorded violations result in the automatic submission of the answer paper
            and termination of the session.</p>
          {requireCamera && (
            <p>2.3 The webcam remains active for the duration of the examination. Images are processed on the
              candidate's own device. A single still image is transmitted to an invigilator only where the
              system identifies a mobile telephone, more than one person, or the absence of the candidate.</p>
          )}
          {requireMic && (
            <p>2.4 Microphone permission is required for the duration of the examination.</p>
          )}

          <h3 style={{ fontSize: 13.5 }}>3. Review by invigilators</h3>
          <p>3.1 No candidate is penalised automatically on the basis of camera monitoring. Each image is
            reviewed by an invigilator, who alone determines whether a violation is recorded.</p>
          <p>3.2 Images are deleted immediately upon review, and in any event within thirty minutes. No image
            is retained against a candidate's record.</p>

          <h3 style={{ fontSize: 13.5 }}>4. Retention and access</h3>
          <p>4.1 The identification photograph, answers, marks and violation log are retained until the
            declaration of results and the conclusion of any appeal arising from this examination.</p>
          <p>4.2 These records are accessible only to the examination office and to authorised invigilators.</p>

          <h3 style={{ fontSize: 13.5 }}>5. Conduct</h3>
          <p>5.1 The candidate shall attempt the examination alone, without assistance, and without reference
            to any other person, device or material.</p>
          <p>5.2 One attempt is permitted per candidate. Once the examination begins, the session is
            restricted to a single device.</p>
          <p>5.3 The examination is submitted automatically on expiry of the candidate's {minutes ?? 15} minutes
            or on the closing of the round, whichever occurs earlier.</p>

          <h3 style={{ fontSize: 13.5 }}>6. Declaration</h3>
          <p>By accepting below, the candidate confirms that: (a) the candidate is the person registered for
            this examination; (b) the candidate consents to the monitoring described in clause 2; and
            (c) the candidate has read and accepts the rules set out in clause 5.</p>
          <p className="muted">Queries concerning personal data may be addressed to the examination office.</p>
        </div>

        <label className="row" style={{ fontWeight: 600, marginTop: 14, alignItems: 'flex-start' }}>
          <input type="checkbox" style={{ width: 'auto', marginTop: 3 }}
                 checked={ticked} onChange={e => setTicked(e.target.checked)} />
          <span>I have read, understood and accept the terms set out above.</span>
        </label>

        <div className="row" style={{ marginTop: 14 }}>
          <button className="lg" disabled={!ticked || busy} onClick={onAgree}>
            {busy ? 'Recording…' : 'Accept and begin examination'}
          </button>
          <button className="ghost" disabled={busy} onClick={onCancel}>Cancel</button>
        </div>
      </div>
    </div>
  )
}
