// Webcam access for exam monitoring.
//
// Frames are analysed in the student's own browser. A snapshot leaves the machine ONLY
// when the detector sees something worth a proctor's attention, and even then it is held
// in the review queue until a proctor looks at it, then deleted. Nothing is archived.

let stream = null

export async function requestCamera() {
  if (cameraLive()) return true
  stream = await navigator.mediaDevices.getUserMedia({
    video: { width: { ideal: 640 }, height: { ideal: 480 }, facingMode: 'user' },
    audio: false,
  })
  return true
}

export const cameraStream = () => stream
export const cameraLive = () => Boolean(stream && stream.getVideoTracks().some(t => t.readyState === 'live'))

export function releaseCamera() {
  stream?.getTracks().forEach(t => t.stop())
  stream = null
}

const supportsWebp = () => {
  try {
    return document.createElement('canvas').toDataURL('image/webp').startsWith('data:image/webp')
  } catch { return false }
}

/** A small WebP still of the current frame — roughly 25-40 KB. */
export function captureFrame(video, { maxDim = 480, quality = 0.6 } = {}) {
  if (!video || !video.videoWidth) return null
  const scale = Math.min(1, maxDim / Math.max(video.videoWidth, video.videoHeight))
  const canvas = document.createElement('canvas')
  canvas.width = Math.round(video.videoWidth * scale)
  canvas.height = Math.round(video.videoHeight * scale)
  canvas.getContext('2d').drawImage(video, 0, 0, canvas.width, canvas.height)
  const mime = supportsWebp() ? 'image/webp' : 'image/jpeg'
  const b64 = canvas.toDataURL(mime, quality).split(',')[1]
  return { mime, b64 }
}
