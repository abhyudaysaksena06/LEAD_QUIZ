// Microphone access.
//
// The stream is requested so the student grants permission and the browser's
// "microphone in use" indicator stays lit for the duration of the test.
// NOTHING is recorded, analysed, transmitted or stored: no MediaRecorder, no
// AudioContext, no upload. The MediaStream is held open and then released.
//
// Keep any wording shown to students factual ("microphone access is required"),
// not a claim that audio is being captured.

let stream = null

export async function requestMic() {
  if (stream && stream.getAudioTracks().some(t => t.readyState === 'live')) return true
  stream = await navigator.mediaDevices.getUserMedia({ audio: true })
  return true
}

export function micLive() {
  return Boolean(stream && stream.getAudioTracks().some(t => t.readyState === 'live'))
}

export function releaseMic() {
  stream?.getTracks().forEach(t => t.stop())
  stream = null
}
