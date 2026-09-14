// In-browser object detection (TensorFlow.js COCO-SSD).
//
// We only care about two of its classes: `person` and `cell phone`. Everything runs on
// the student's machine — no frame is uploaded unless a detection needs a human to look.
//
// Nothing here flags anybody. It only decides "is this worth a proctor's attention?".

let modelPromise = null

export function loadDetector() {
  if (!modelPromise) {
    modelPromise = (async () => {
      const tf = await import('@tensorflow/tfjs')
      await tf.ready()
      const cocoSsd = await import('@tensorflow-models/coco-ssd')
      // lite_mobilenet_v2: ~6 MB, fast enough on modest laptops
      return cocoSsd.load({ base: 'lite_mobilenet_v2' })
    })()
    modelPromise.catch(() => { modelPromise = null })   // allow a retry later
  }
  return modelPromise
}

const PERSON_MIN = 0.5
const PHONE_MIN = 0.45

export async function analyse(video) {
  const model = await loadDetector()
  const preds = await model.detect(video, 12, 0.3)
  const people = preds.filter(p => p.class === 'person' && p.score >= PERSON_MIN)
  const phones = preds.filter(p => p.class === 'cell phone' && p.score >= PHONE_MIN)
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
