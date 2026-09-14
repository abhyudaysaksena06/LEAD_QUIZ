# LEAD Quiz Portal

Proctored quiz: roll-number login, individual 15-minute timer, 17 MCQ + 3 coding questions
drawn at random per student, fullscreen screen control (3 violations → auto-submit + sign-out),
in-screen code editor with a runnable terminal, student ↔ admin chat, and an admin portal.

**Stack:** React + Vite · Supabase (Postgres). All data access goes through Postgres functions;
the tables live in a private schema the browser cannot reach, and answer keys never leave the database.

---

## 1. Set up the database (Supabase)

1. Create a project at [supabase.com](https://supabase.com).
2. Open **SQL Editor → New query** and run the files in `supabase/` **in order**
   (or run `supabase/ALL_IN_ONE.sql` once — it's the same four files combined):

   | File | What it does |
   |---|---|
   | `01_schema.sql` | Tables (private `quiz` schema), helpers |
   | `02_student_api.sql` | Student functions: login, start, save, violations, submit, chat |
   | `03_admin_api.sql` | Admin functions + permissions |
   | `04_seed.sql` | Test student, admin account, placeholder questions |

   All files are safe to re-run.

3. **Change the admin password** (default is `admin` / `LEADADMIN`):
   ```sql
   update quiz.admins set password_hash = quiz.hash_password('YOUR-STRONG-PASSWORD') where username = 'admin';
   ```

## 2. Run the app

```bash
cp .env.example .env      # then paste your Project URL + anon key (Settings → API)
npm install
npm run dev               # http://localhost:5173
```

| Page | URL | Login |
|---|---|---|
| Student | `/` | `1025030923` / `JAILEAD` |
| Admin | `/admin/login` | `admin` / `LEADADMIN` |

**Deploy:** `npm run build` and host `dist/` (Vercel / Netlify). `vercel.json` is included so
`/admin` and `/exam` work on refresh. Set the two `VITE_` env vars in the host's dashboard.

---

## 3. Adding students

Username = roll number. Either:

- **Admin portal → Students** — paste one per line: `roll_no,password,full name`
- **SQL** — edit and run `supabase/05_add_students_template.sql`

Re-adding an existing roll number updates its password.

## 3a. Registration (Google + photo ID)

Students are authorised by **email address**, not by a roll number you type in advance.

1. **Admin → Registrations** — paste the Gmail addresses allowed to sit the test
   (`email`, or `email, name, roll number` to pre-fill their form) and pick the round.
2. **Students sign in with Google, hours before the test.** An address that isn't on the
   list is refused.
3. On their first sign-in they complete a one-time form: **full name, roll number, and a
   photo of their ID**. The photo is compressed in their browser (~100–200 KB) and stored
   in the database; view it any time from **Registrations → View** or a student's panel.
4. They then wait on the "your round hasn't started" screen. It unlocks by itself within
   10 seconds of you opening their round.

Roll numbers are typed by the students, so the database rejects duplicates and you can see
every name/roll/ID pairing in Registrations before the test begins. Run registration a few
hours ahead — that's when login problems are cheap to fix.

## 3b. Rounds — controlling when each group starts

Every student belongs to a **batch**. A student can only press Start when **their batch is open**,
and still only gets **one attempt**.

- **Admin → Batches** lists every batch with live counts and a **▶ Start batch** button.
  Starting a batch is what lets that group begin.
- **Closing** a batch stops *new* starts. Students already writing are **not** interrupted.
- Each batch can override the duration (blank = use the global setting).
- The **master switch** in Settings overrides everything: if the exam is closed, nobody starts.
- Assign students to a batch in **Admin → Students** (the dropdown moves existing students too).
- A student whose batch is still closed sees a waiting message, and the page **unlocks by itself**
  within 10 seconds of you starting their batch — they don't need to refresh.

To rehearse, run `supabase/06_test_batches.sql`: it creates Batch 1–8 (all closed) with one test
student each — `1025030923`, then `TESTB2` … `TESTB8`, password `JAILEAD` for all. Re-running it
clears their attempts so you can practise repeatedly. Remove them before the real exam:

```sql
delete from quiz.students where roll_no like 'TESTB%';
```

## 3c. Proctor logins and how chat load is shared

Run `supabase/08_proctors.sql` to create five logins: `proctor1` … `proctor5`
(passwords `LEAD-P1-2026` … `LEAD-P5-2026` — **change them**). The original `admin`
login still works and behaves the same way.

When a student sends their first message, the thread is **assigned to the signed-in
proctor with the fewest open conversations**, so nobody ends up carrying the room:

- A proctor counts as **active** while their portal is open (it polls every 5 seconds).
  45 seconds of silence and they're treated as offline.
- If a proctor goes offline mid-exam, **their open threads are handed to the others
  automatically** — nothing gets stranded.
- If nobody is signed in, threads wait as **unassigned** and are picked up the moment
  the first proctor appears.
- A conversation stays with the same proctor while they're online, so students aren't
  passed around mid-sentence.

In **Admin → Chat**: **Mine** is your queue, **All** shows everything, **Done** is resolved.
The strip at the top shows every proctor, whether they're online, and how many threads
they're holding. **Take over** pulls a thread to you; **Mark done** closes it and frees
your capacity so the next query routes elsewhere.

## 4. Replacing the placeholder questions

Each student gets a **random** 17 MCQ + 3 coding from the bank, in their own order, with
options shuffled per student. Put in more than 17/3 so papers differ between students.

```sql
-- remove placeholders (only BEFORE any student has started)
delete from quiz.questions;

-- MCQ: correct_index is 0-based (0 = first option)
insert into quiz.questions (kind, title, body, options, correct_index, marks) values
('mcq', 'Big-O', 'What is the time complexity of binary search?',
 '["O(n)", "O(log n)", "O(n log n)", "O(1)"]', 1, 1);

-- Coding: graded by comparing program output against test cases
with q as (
  insert into quiz.questions (kind, title, body, starter_code, language, marks) values
  ('coding', 'Reverse a string', E'Read a line and print it reversed.\n\nInput: hello\nOutput: olleh',
   E's = input()\n', 'python', 5)
  returning id
)
insert into quiz.question_tests (question_id, ord, stdin, expected_output, is_sample, points)
select q.id, v.ord, v.stdin, v.expected, v.sample, 1 from q, (values
  (1, 'hello',  'olleh',  true),    -- is_sample = true  -> the student can run this one
  (2, 'abcd',   'dcba',   false),   -- hidden: expected output NEVER sent to students
  (3, 'a',      'a',      false)
) as v(ord, stdin, expected, sample);
```

**How coding is graded.** Admin → **Submissions** → *Auto-grade coding answers* re-runs each student's
saved code **in the admin's browser** against every test case and stores the result. Marks are computed
by the database as `question marks × (points of passed tests ÷ total points)`, so a student can't fake a
pass from their own machine. You can override any mark by opening the student. Coding questions are
always **optional** for students; set *Coding per student* to `0` in Settings for an MCQ-only exam.

If students have already started, deactivate instead of deleting: `update quiz.questions set active = false where id = …;`

Paper size and limits live in `quiz.config` (`mcq_count`, `coding_count`, `max_flags`, `duration_minutes`).

---

## 5. On exam day

1. **Settings → Exam open** off until you're ready; turn it on to let students press Start.
2. **Dashboard** refreshes every 5s: status, violations, answered count, time left.
3. **Blocked student?** Type the roll number → *Open* → **Unblock**. A reason is required.
   The time they had left is restored automatically; violations reset to 2 by default.
4. **Chat** tab: every student message, unread first. *Broadcast* messages everyone.
5. **Export results CSV** from the dashboard. Grade coding answers in each student's panel.

## 6. What screen control can and can't do

A web page **cannot** stop the operating system from switching apps. This app:

- **Locks keys in fullscreen** on Chrome/Edge (Keyboard Lock API): Alt+Tab, the Windows key and Esc
  are captured; Esc must be *held* to leave fullscreen.
- **Detects** leaving fullscreen, switching tabs, or focusing another window → a violation.
  Several events from one action count once (5-second window). 3 violations → auto-submit + sign-out.
- **Hides the questions** whenever the window isn't fullscreen and focused.
- Blocks copy/paste, right-click, DevTools shortcuts, printing. Paste into the code editor is only
  allowed for code copied from inside the editor.

For machines you control (a lab), launch Chrome in kiosk mode — this *does* prevent switching:

```bash
chrome --kiosk https://your-quiz-url
```

**Use Chrome or Edge.** Keyboard Lock isn't available in Firefox/Safari (detection still works).

## 7. Coding terminal

Python 3 (via Pyodide, downloaded on first Run) and JavaScript run **in the student's browser**
with a timeout. C, C++ and Java can be written and are saved, but can't be run in the browser.
All coding answers are graded manually in the admin portal.

## 8. Notes

- Students' answers save on every click/keystroke and resume after a refresh or crash.
- The timer is enforced by the server; a closed laptop can't pause it.
- Chat and status use lightweight polling (no Realtime connections), so 450+ students
  won't hit Supabase's Realtime connection limits.
