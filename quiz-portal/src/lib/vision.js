// In-browser object detection (TensorFlow.js COCO-SSD).
//
// We only care about two of its classes: `person` and `cell phone`. Everything runs on
// the student's machine — no frame is uploaded unless a detection needs a human to look.
//
// Nothing here flags anybody. It only decides "is this worth a proctor's attention?".

let modelPromise = null
let ready = false
let lastError = null

export const detectorReady = () => ready
export const detectorError = () => lastError

export function loadDetector() {
  if (!modelPromise) {
    modelPromise = (async () => {
      const tf = await import('@tensorflow/tfjs')
      await tf.ready()
      const cocoSsd = await import('@tensorflow-models/coco-ssd')
      // mobilenet_v2 (the default) is markedly better at small objects such as a
      // phone than lite_mobilenet_v2. It is a larger download but only fetched once.
      const model = await cocoSsd.load({ base: 'mobilenet_v2' })
      ready = true; lastError = null
      return model
    })()
    modelPromise.catch(e => {
      ready = false
      lastError = String(e?.message || e)
      modelPromise = null           // allow a retry later
    })
  }
  return modelPromise
}

const PERSON_MIN = 0.45

// Phone detection is imperfect either way: set it too high and a phone held in plain
// sight is missed; too low and wallets and cases trigger it. Since every detection is
// reviewed by a person before it counts, we favour catching it and let the proctor
// throw out the false ones.
const PHONE_MIN = 0.35
const PHONE_MIN_AREA = 0.004   // ignore only very small specks

export async function analyse(video, { detectPhone = true } = {}) {
  const model = await loadDetector()
  const preds = await model.detect(video, 12, 0.25)
  const frame = Math.max(1, (video.videoWidth || 0) * (video.videoHeight || 0))
  const people = preds.filter(p => p.class === 'person' && p.score >= PERSON_MIN)
  const phones = !detectPhone ? [] : preds.filter(p =>
    p.class === 'cell phone' && p.score >= PHONE_MIN
    && (p.bbox[2] * p.bbox[3]) / frame >= PHONE_MIN_AREA)
  return {
    people: people.length,
    phones: phones.length,
    detail: {
      people: people.map(p => +p.score.toFixed(2)),
      phones: phones.map(p => +p.score.toFixed(2)),
      others: preds.filter(p => !['person', 'cell phone'].includes(p.class))
                   .map(p => `${p.class} ${p.score.toFixed(2)}`).slice(0, 4),
    },
  }
}

/** What (if anything) deserves review. Null means everything looks normal. */
export function classify({ people, phones }) {
  if (phones > 0) return 'PHONE_DETECTED'
  if (people > 1) return 'MULTIPLE_PEOPLE'
  if (people === 0) return 'NO_PERSON'
  return null
}
