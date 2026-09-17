import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import './styles.css'
import { configured } from './lib/api'
import StudentLogin from './pages/StudentLogin'
import PublicQuiz from './pages/PublicQuiz'
import Exam from './pages/Exam'
import AdminLogin from './pages/AdminLogin'
import Admin from './pages/Admin'

function NotConfigured() {
  return (
    <div className="center-page">
      <div className="card narrow">
        <h1>Setup needed</h1>
        <p>Create a <code>.env</code> file in the project root with:</p>
        <pre className="snippet">VITE_SUPABASE_URL=https://YOUR-PROJECT.supabase.co{'\n'}VITE_SUPABASE_ANON_KEY=your-anon-key</pre>
        <p className="muted">Then restart <code>npm run dev</code>.</p>
      </div>
    </div>
  )
}

createRoot(document.getElementById('root')).render(
  <StrictMode>
    {!configured ? <NotConfigured /> : (
      <BrowserRouter>
        <Routes>
          <Route path="/" element={<PublicQuiz />} />
          <Route path="/public" element={<PublicQuiz />} />
          <Route path="/recruitment" element={<StudentLogin />} />
          <Route path="/exam" element={<Exam />} />
          <Route path="/admin/login" element={<AdminLogin />} />
          <Route path="/admin" element={<Admin />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </BrowserRouter>
    )}
  </StrictMode>,
)
