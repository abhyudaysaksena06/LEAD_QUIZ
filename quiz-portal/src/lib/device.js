// A stable id for this browser. Sent at sign-in and on every heartbeat so the
// server can tell that one account is being used from two places at once.
const KEY = 'lead-device-id'

export function deviceId() {
  try {
    let v = localStorage.getItem(KEY)
    if (!v) {
      v = (crypto.randomUUID?.() || String(Math.random()).slice(2) + Date.now())
      localStorage.setItem(KEY, v)
    }
    return v
  } catch {
    return 'no-storage'
  }
}
