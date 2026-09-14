// Shrink a photo of an ID card before storing it.
// Phone photos are 3-8 MB; WebP at ~900px gives a clearly readable ID card in 40-80 KB,
// roughly a third of the equivalent JPEG. Falls back to JPEG on browsers without WebP
// encoding (older Safari). The database rejects anything over ~675 KB.

const MAX_B64 = 860_000   // stay under the database limit with room to spare

const readAsDataUrl = file => new Promise((resolve, reject) => {
  const r = new FileReader()
  r.onload = () => resolve(r.result)
  r.onerror = () => reject(new Error('Could not read that file.'))
  r.readAsDataURL(file)
})

const loadImage = src => new Promise((resolve, reject) => {
  const img = new Image()
  img.onload = () => resolve(img)
  img.onerror = () => reject(new Error('That file is not an image we can read.'))
  img.src = src
})

const supportsWebp = () => {
  try {
    return document.createElement('canvas').toDataURL('image/webp').startsWith('data:image/webp')
  } catch { return false }
}

export async function compressImage(file, { maxDim = 900 } = {}) {
  if (!file.type.startsWith('image/')) {
    throw new Error('Please upload a photo of your ID (JPG, PNG or WebP).')
  }
  const img = await loadImage(await readAsDataUrl(file))
  const scale = Math.min(1, maxDim / Math.max(img.width, img.height))
  const canvas = document.createElement('canvas')
  canvas.width = Math.round(img.width * scale)
  canvas.height = Math.round(img.height * scale)
  const ctx = canvas.getContext('2d')
  ctx.imageSmoothingQuality = 'high'
  ctx.drawImage(img, 0, 0, canvas.width, canvas.height)

  const mime = supportsWebp() ? 'image/webp' : 'image/jpeg'
  for (const q of [0.8, 0.65, 0.5, 0.38]) {
    const dataUrl = canvas.toDataURL(mime, q)
    const b64 = dataUrl.split(',')[1]
    if (b64.length <= MAX_B64) {
      return { mime, b64, dataUrl, bytes: Math.round((b64.length * 3) / 4) }
    }
  }
  throw new Error('That image is too large even after compression — please try a smaller photo.')
}
