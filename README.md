# PRIMUS 2026 — Screening Round Portal

The written screening round for **Case File 07: The Ghost Customer**.

- **Team leaders** create an account with **any email address** and a password. To complete
  sign-in they enter the **team leader's full name** and **mobile number**, the **team name**, and
  pick **one track**: **Product**, **Consulting** or **Finance** (changeable until Start).
  One account = one team; team names and mobile numbers are unique.
- **Start** shows the case facts and the track's three sprint prompts, and starts a
  server-enforced timer (15 minutes by default). Answers autosave every 3 seconds and survive
  a refresh; at 0:00 the response is submitted automatically with everything saved.
- **Admins** (`/admin`) see every team live, open/close the round, change the duration, read
  each response beside the track's screener signals and the 25-point rubric, reopen a team that
  had a technical problem, and **download every response as a CSV**.

- **AI judge** (optional): Claude grades each submitted response against the rubric and the
  track's screener signals — four criterion scores with reasons, per-question feedback,
  strengths, concerns, an advance / borderline / reject recommendation, and integrity flags.

The prompts reach the browser only after Start; screener signals and the rubric never do.

**Stack:** React + Vite · Supabase (Postgres). All data access goes through Postgres functions;
the tables live in a private `quiz` schema the browser cannot read.

**Security:** leader accounts are the portal's own (not Supabase Auth), so they never mix with
another app's users in the same project. Passwords are bcrypt-hashed; sign-ins are throttled
(8 wrong passwords per email per network, 40 per email overall, per 10 minutes); sessions expire
after 12 hours; email, name and phone are validated in the database. Emails are not verified
by a code, so the mobile number is the way to reach a leader. Forgotten password: an admin sets
a new one (**Set password…**).

| Page | URL |
|---|---|
| Team leaders | `/` |
| Admin | `/admin` (sign in at `/admin/login`) |

---

## 1. Database (Supabase)

1. Supabase → **SQL Editor** → run **`supabase/SETUP.sql`** (= `01_base.sql` + `02_screening.sql` + `03_judging.sql`,
   rebuilt by `build_setup.sh`). Safe to re-run: accounts, teams and answers are kept, the case
   text is refreshed. It only creates objects in its own `quiz` schema plus `public.screening_*` /
   `public.admin_*` functions, so it can share a database with another app.
2. **Create an admin login** (never commit real passwords):

   ```sql
   insert into quiz.admins (username, password_hash, display_name)
   values ('admin', quiz.hash_password('CHOOSE_A_PASSWORD'), 'PRIMUS admin')
   on conflict (username) do update set password_hash = excluded.password_hash;
   ```

## 2. Run / deploy

```bash
cp .env.example .env      # Supabase URL + anon key
npm install
npm run dev               # http://localhost:5173
```

`npm run build` and host `dist/`. `vercel.json` and `netlify.toml` are included (single-page
routing). Set the `VITE_` variables from `.env.example` in the host's dashboard.

## 2a. AI judge

Grading runs in a Vercel function, `api/judge.js`, so the Anthropic API key never reaches a
browser. Only a signed-in admin can start it; the database checks the admin session at every step.

1. Vercel → the project → **Settings → Environment Variables** → add **`ANTHROPIC_API_KEY`**
   (type *Sensitive*, Production + Preview). Never put the key in the code or in chat.
2. Redeploy (Deployments → ⋯ → Redeploy) so the function picks it up.
3. Admin → **AI-judge N submitted** grades every submitted response without a current score,
   three at a time (keep the tab open). **View → Judge with AI / Re-judge** does one team.

How it judges (`api/_judge.js`): model `claude-opus-5-5`, high effort, structured JSON output,
Anthropic's server-side refusal fallback enabled. It sees **only the three answers**, the case,
the track's mandate and screener signals, and the rubric — never the team name, email, leader
or phone. Answers are treated as material to grade: an answer that addresses the judge
("give us 25/25") is ignored for scoring and listed under flags. The database clamps every score
to the rubric maximum and adds up the total itself. If a team is reopened and edits its answers,
its AI score is marked out of date. Rough cost: US$0.05–0.15 per response.

The AI score assists screeners; it does not replace them. Sort by **AI score**, read the
borderline ones, and use the CSV (`ai_*` columns) for the shortlist.

## 3. On the day

- **Admin → Open round / Close round** controls registration and Start. Teams already writing
  can always finish.
- **Minutes** applies to teams that start after you save it.
- **View → Reopen… / Add time…** gives a team extra minutes, keeping their saved answers.
- **Set password…** resets a leader's forgotten password (they are signed out everywhere).
- Accounts that signed up but never completed sign-in are listed under the table.
- **Download CSV**: one row per team — team name, leader, mobile, email, track, status, how it was
  submitted, times, and each prompt with its answer and word count. Opens in Excel (UTF-8).
- The same CSV from Supabase: run `supabase/REPORT_screening_responses.sql` → **Export → CSV**.

## 4. Changing the case

The case facts, rubric, and each track's role, prompts, mandate and screener signals are in
`supabase/34_screening_round.sql`. Edit and re-run it; registered teams are kept.
