# PRIMUS 2026 — Screening Round Portal

The written screening round for **Case File 07: The Ghost Customer**.

- **Team leaders** sign in with Google, enter their **team name**, and pick **one track**:
  **Product**, **Consulting** or **Finance**. Both can be changed until they press Start.
  One Google account = one team; team names are unique.
- **Start** shows the case facts and the track's three sprint prompts, and starts a
  server-enforced timer (15 minutes by default). Answers autosave every 3 seconds and survive
  a refresh; at 0:00 the response is submitted automatically with everything saved.
- **Admins** (`/admin`) see every team live, open/close the round, change the duration, read
  each response beside the track's screener signals and the 25-point rubric, reopen a team that
  had a technical problem, and **download every response as a CSV**.

The prompts reach the browser only after Start; screener signals and the rubric never do.

**Stack:** React + Vite · Supabase (Postgres) · Firebase Google sign-in. All data access goes
through Postgres functions; the tables live in a private `quiz` schema the browser cannot read.

| Page | URL |
|---|---|
| Team leaders | `/` |
| Admin | `/admin` (sign in at `/admin/login`) |

---

## 1. Database (Supabase)

1. Supabase → **SQL Editor** → run **`supabase/SCREENING_STANDALONE.sql`**
   (= `34a_screening_base.sql` + `34_screening_round.sql`). Safe to re-run: teams and answers
   are kept, the case text is refreshed. It only creates objects in its own `quiz` schema plus
   `public.screening_*` / `public.admin_*` functions, so it can share a database with another app.
2. **Create an admin login** (never commit real passwords):

   ```sql
   insert into quiz.admins (username, password_hash, display_name)
   values ('admin', quiz.hash_password('CHOOSE_A_PASSWORD'), 'PRIMUS admin')
   on conflict (username) do update set password_hash = excluded.password_hash;
   ```
3. **Trust Google sign-in:** Supabase → Authentication → Third-Party Auth → Add provider →
   **Firebase** → your Firebase project ID. The database reads the leader's email from that
   verified token, so nobody can claim someone else's address.

## 2. Run / deploy

```bash
cp .env.example .env      # Supabase URL + anon key, Firebase web config
npm install
npm run dev               # http://localhost:5173
```

`npm run build` and host `dist/`. `vercel.json` and `netlify.toml` are included (single-page
routing). Set the `VITE_` variables from `.env.example` in the host's dashboard.

## 3. On the day

- **Admin → Open round / Close round** controls registration and Start. Teams already writing
  can always finish.
- **Minutes** applies to teams that start after you save it.
- **View → Reopen… / Add time…** gives a team extra minutes, keeping their saved answers.
- **Download CSV**: one row per team — team name, leader, email, track, status, how it was
  submitted, times, and each prompt with its answer and word count. Opens in Excel (UTF-8).
- The same CSV from Supabase: run `supabase/REPORT_screening_responses.sql` → **Export → CSV**.

## 4. Changing the case

The case facts, rubric, and each track's role, prompts, mandate and screener signals are in
`supabase/34_screening_round.sql`. Edit and re-run it; registered teams are kept.
