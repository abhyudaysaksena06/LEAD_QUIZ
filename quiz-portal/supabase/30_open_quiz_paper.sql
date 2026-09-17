-- =====================================================================
-- LEAD Quiz Portal — 30: the Open Quiz paper (50 questions, Set 2)
--
-- Loaded from LEAD_Open_Quiz.md. These questions belong ONLY to the open
-- quiz (question_set = 'open_quiz'); the recruitment rounds never draw them,
-- and the open quiz never draws recruitment questions.
--
-- Same 20-question pattern as the recruitment quiz, drawn fresh for every
-- candidate: 4 logical reasoning, 3 design, 3 marketing/events and 7 technical
-- from this set, plus 3 optional coding questions from the existing coding
-- bank (this set has none). Order and options are shuffled per candidate (the
-- source key is mostly B, so shuffling matters). Answer keys stay server-side.
-- Same 20-minute timer. Safe to re-run.
-- =====================================================================

alter table quiz.questions add column if not exists question_set text not null default 'recruitment';

insert into quiz.questions (kind, question_set, ext_code, title, section, body, options, correct_index, marks, active)
select 'mcq', 'open_quiz', v.ext, v.title, v.sec, v.body, v.opts, v.ci, 1, true
from (values
  ('OQ1', 'Open Quiz Q1', 'TECH', 'What is the output?
```c
void modify(int **pp) {
    static int b = 20;
    *pp = &b;
}
int main() {
    int a = 10;
    int *p = &a;
    modify(&p);
    printf("%d", *p);
}
```', '["10", "20", "Garbage value", "Segmentation fault"]'::jsonb, 1),
  ('OQ2', 'Open Quiz Q2', 'TECH', 'What is the output?
```c
int x = 5;
int y = ++x + ++x;
printf("%d", y);
```', '["12", "13", "14", "Undefined behavior"]'::jsonb, 3),
  ('OQ3', 'Open Quiz Q3', 'TECH', 'What is the output?
```c
struct S { char a; int b; char c; };
printf("%lu", sizeof(struct S));
```', '["6", "8", "12", "9"]'::jsonb, 2),
  ('OQ4', 'Open Quiz Q4', 'TECH', 'What is the output?
```c
char *p = "Hello";
char q[] = "Hello";
printf("%lu %lu", sizeof(p), sizeof(q));
```', '["5 5", "6 6", "8 6", "8 5"]'::jsonb, 2),
  ('OQ5', 'Open Quiz Q5', 'TECH', 'What is the output?
```c
int a = 10, b = 5;
int c = (a > b) ? (a += 10, a) : (b += 10, b);
printf("%d %d %d", a, b, c);
```', '["20 5 20", "10 15 15", "20 15 20", "10 5 10"]'::jsonb, 0),
  ('OQ6', 'Open Quiz Q6', 'TECH', 'What is the output?
```c
int arr[] = {1, 2, 3, 4, 5};
int *p = arr + 4;
printf("%d", *(p - 2));
```', '["1", "2", "3", "4"]'::jsonb, 2),
  ('OQ7', 'Open Quiz Q7', 'TECH', 'What is the output?
```c
int foo(int n) {
    if (n == 0) return 0;
    if (n == 1) return 1;
    return foo(n-1) + foo(n-2);
}
printf("%d", foo(7));
```', '["7", "13", "21", "8"]'::jsonb, 1),
  ('OQ8', 'Open Quiz Q8', 'TECH', 'What is the output?
```python
def make_counters():
    counters = []
    for i in range(3):
        def counter(i=i):
            return i
        counters.append(counter)
    return counters

print([c() for c in make_counters()])
```', '["[2, 2, 2]", "[0, 1, 2]", "[3, 3, 3]", "Error"]'::jsonb, 1),
  ('OQ9', 'Open Quiz Q9', 'TECH', 'What is the output?
```python
class A:
    def show(self): print("A", end=" ")
class B(A):
    def show(self): print("B", end=" ")
class C(A):
    def show(self): print("C", end=" ")
class D(B, C):
    pass

d = D()
d.show()
print(D.__mro__)
```', '["A is printed; MRO is D→A→B→C", "B is printed; MRO is D→B→C→A→object", "C is printed; MRO is D→C→B→A→object", "Error — diamond inheritance not allowed"]'::jsonb, 1),
  ('OQ10', 'Open Quiz Q10', 'TECH', 'What is the output?
```python
a = [[0] * 3] * 3
a[0][0] = 5
print(a)
```', '["[[5, 0, 0], [0, 0, 0], [0, 0, 0]]", "[[5, 0, 0], [5, 0, 0], [5, 0, 0]]", "[[5, 5, 5], [5, 5, 5], [5, 5, 5]]", "Error"]'::jsonb, 1),
  ('OQ11', 'Open Quiz Q11', 'TECH', 'What is the output?
```python
def gen():
    val = yield 1
    yield val + 10

g = gen()
print(next(g))
print(g.send(5))
```', '["1 then 15", "1 then 11", "5 then 15", "Error"]'::jsonb, 0),
  ('OQ12', 'Open Quiz Q12', 'TECH', 'What is the output?
```python
x = {''a'': 1, ''b'': 2}
y = {''b'': 3, ''c'': 4}
z = {**x, **y}
print(z)
```', '["{''a'': 1, ''b'': 2, ''c'': 4}", "{''a'': 1, ''b'': 3, ''c'': 4}", "{''a'': 1, ''b'': 2, ''b'': 3, ''c'': 4}", "Error — duplicate keys not allowed"]'::jsonb, 1),
  ('OQ13', 'Open Quiz Q13', 'TECH', 'What is the output?
```python
class Tracker:
    instances = 0
    def __init__(self):
        Tracker.instances += 1
    def __del__(self):
        Tracker.instances -= 1

a = Tracker()
b = Tracker()
del a
print(Tracker.instances)
```', '["0", "1", "2", "Depends on garbage collector timing"]'::jsonb, 1),
  ('OQ14', 'Open Quiz Q14', 'TECH', 'What is the output?
```python
try:
    try:
        raise ValueError("inner")
    except ValueError:
        print("Caught inner", end=" ")
        raise TypeError("re-raised")
except TypeError:
    print("Caught outer", end=" ")
finally:
    print("Finally")
```', '["Caught inner Finally", "Caught inner Caught outer Finally", "Caught outer Finally", "Error — can''t raise inside except"]'::jsonb, 1),
  ('OQ15', 'Open Quiz Q15', 'TECH', 'In deep neural networks, what is the "vanishing gradient problem"?', '["Gradients become extremely large, causing weights to explode", "During backpropagation, gradients become progressively smaller as they propagate to earlier layers, causing those layers to learn extremely slowly or stop learning", "The gradient disappears because the learning rate is too high", "It only occurs in unsupervised learning"]'::jsonb, 1),
  ('OQ16', 'Open Quiz Q16', 'TECH', 'You have a dataset with 10,000 features but only 100 samples. Your model performs poorly. This is MOST likely due to:', '["The model is too simple", "The curse of dimensionality — too many features relative to samples leads to sparse data, making it nearly impossible to find meaningful patterns", "The model needs more layers", "The learning rate is too low"]'::jsonb, 1),
  ('OQ17', 'Open Quiz Q17', 'TECH', 'A fraud detection system flags 100 transactions as fraudulent. Of these, 90 are actually legitimate (false positives) and only 10 are real fraud. The system catches 10 out of 12 total real fraud cases. What are the system''s precision and recall?', '["Precision 90%, Recall 83%", "Precision 10%, Recall 83%", "Precision 83%, Recall 10%", "Precision 10%, Recall 90%"]'::jsonb, 1),
  ('OQ18', 'Open Quiz Q18', 'TECH', 'What is the key difference between L1 (Lasso) and L2 (Ridge) regularization?', '["L1 and L2 are identical — just different names", "L1 adds the absolute value of weights as a penalty (can force some weights to exactly zero, performing feature selection); L2 adds the square of weights (shrinks all weights but rarely makes them exactly zero)", "L2 performs feature selection; L1 does not", "L1 is always better than L2"]'::jsonb, 1),
  ('OQ19', 'Open Quiz Q19', 'A', 'Find the next number: 2, 3, 10, 15, 26, 35, ?', '["48", "50", "46", "52"]'::jsonb, 1),
  ('OQ20', 'Open Quiz Q20', 'A', 'Find the missing number: 4, 18, 48, 100, 180, ?', '["290", "294", "288", "300"]'::jsonb, 1),
  ('OQ21', 'Open Quiz Q21', 'A', 'Find the next term: 1, 2, 6, 42, 1806, ?', '["3263442", "3263440", "3263444", "Cannot be determined"]'::jsonb, 0),
  ('OQ22', 'Open Quiz Q22', 'A', 'Find the next number: 1, 4, 9, 1, 6, 2, 5, 3, 6, ?', '["4", "7", "9", "49"]'::jsonb, 0),
  ('OQ23', 'Open Quiz Q23', 'A', 'In a code language, FRAME is written as GSBNF (each letter +1). What is SOLVE?', '["TPMWF", "TPMWG", "TPNWF", "TQMWF"]'::jsonb, 0),
  ('OQ24', 'Open Quiz Q24', 'A', 'In a code language, "pit dar na" means "you are good", "na ho pit" means "you and good", and "ho dar tok" means "are and smart". What is the code for "smart"?', '["pit", "ho", "tok", "na"]'::jsonb, 2),
  ('OQ25', 'Open Quiz Q25', 'A', 'A is B''s father. C is A''s mother. D is C''s son. E is D''s wife. How is E related to A?', '["Wife", "Sister-in-law", "Mother", "Daughter-in-law"]'::jsonb, 1),
  ('OQ26', 'Open Quiz Q26', 'A', 'Pointing to a photo, Priya says: "He is the son of the only daughter of the mother of my brother." How is the person in the photo related to Priya?', '["Son", "Nephew", "Brother", "Cousin"]'::jsonb, 0),
  ('OQ27', 'Open Quiz Q27', 'A', 'P is the husband of Q. R is the daughter of S. S is the mother of Q. T is the son of P. How is R related to T?', '["Sister", "Cousin", "Aunt", "Mother"]'::jsonb, 2),
  ('OQ28', 'Open Quiz Q28', 'A', 'A man walks 3 km north, 4 km east, 5 km south, and 8 km west. How far and in what direction is he from the starting point?', '["2√5 km, South-West", "2√5 km, North-West", "5 km, South-West", "4.5 km, South-East"]'::jsonb, 0),
  ('OQ29', 'Open Quiz Q29', 'A', 'Ravi starts from home, walks 12 km east, turns left and walks 5 km. What is the shortest distance from home?', '["17 km", "7 km", "13 km", "15 km"]'::jsonb, 2),
  ('OQ30', 'Open Quiz Q30', 'A', 'Facing north-west, a person turns 270° clockwise. Which direction is he facing now?', '["North-East", "South-West", "South-East", "North"]'::jsonb, 1),
  ('OQ31', 'Open Quiz Q31', 'A', 'Statements: All mangoes are fruits. Some fruits are sweet. Some sweet things are expensive. Which conclusion DEFINITELY follows?', '["Some mangoes are sweet", "Some mangoes are expensive", "Some fruits are expensive", "None of these conclusions definitely follow"]'::jsonb, 3),
  ('OQ32', 'Open Quiz Q32', 'A', 'Statements: No square is a circle. All circles are ellipses. Some ellipses are polygons. Conclusion: "Some polygons are circles."', '["Definitely true", "Definitely false", "Does not necessarily follow", "True only if all ellipses are polygons"]'::jsonb, 2),
  ('OQ33', 'Open Quiz Q33', 'A', 'The statement "All X are Y" is given as TRUE. Which of the following MUST also be true?', '["All Y are X", "No X is Y", "Some Y are X", "No Y is X"]'::jsonb, 2),
  ('OQ34', 'Open Quiz Q34', 'A', 'In a row of 40 students, A is 15th from the left and B is 20th from the right. How many students are between A and B?', '["5", "6", "4", "7"]'::jsonb, 0),
  ('OQ35', 'Open Quiz Q35', 'A', 'Six friends P, Q, R, S, T, U sit in a circle facing the center. P is between T and U. Q is to the immediate right of U. R is not next to Q. Who sits opposite P?', '["Q", "R", "S", "T"]'::jsonb, 1),
  ('OQ36', 'Open Quiz Q36', 'A', 'A clock shows 9:15. What is the exact angle between the hour and minute hands?', '["172.5°", "180°", "165°", "187.5°"]'::jsonb, 0),
  ('OQ37', 'Open Quiz Q37', 'A', 'If the 3rd day of a month is a Monday, what day is the 27th of the same month?', '["Wednesday", "Thursday", "Friday", "Saturday"]'::jsonb, 1),
  ('OQ38', 'Open Quiz Q38', 'A', 'A pipe fills a tank in 12 hours. Another pipe empties it in 18 hours. If both are opened simultaneously on an empty tank, how long does it take to fill?', '["30 hours", "36 hours", "24 hours", "48 hours"]'::jsonb, 1),
  ('OQ39', 'Open Quiz Q39', 'B', 'You''re designing a poster and the client says "make the logo bigger." The logo is already prominent. What''s the professional approach?', '["Just make it as large as they want — the client is always right, no discussion needed", "Make it slightly bigger but also explain how visual hierarchy works and suggest alternatives that give it more prominence without disrupting the layout", "Refuse to change anything", "Delete the logo entirely"]'::jsonb, 1),
  ('OQ40', 'Open Quiz Q40', 'B', 'In Canva, you want your poster''s text to be readable when printed at A3 size. Which download setting should you choose?', '["Smallest file size possible", "Standard (96 DPI)", "PDF Print (300 DPI)", "GIF"]'::jsonb, 2),
  ('OQ41', 'Open Quiz Q41', 'B', 'Your event has a "futuristic tech" theme. Which visual style best fits?', '["Watercolor textures with handwritten fonts", "Warm earthy tones with vintage serif fonts", "Dark backgrounds, neon accent colors, geometric shapes, and clean sans-serif fonts", "Pastel colors with floral patterns"]'::jsonb, 2),
  ('OQ42', 'Open Quiz Q42', 'B', 'In Photoshop, you want to select ONLY the sky in a landscape photo to change its color. Which tool is most efficient?', '["Eraser tool", "Brush tool over the sky", "Quick Selection tool or Magic Wand to select the sky region", "Crop tool"]'::jsonb, 2),
  ('OQ43', 'Open Quiz Q43', 'B', 'You''re designing an Instagram carousel (multiple slides). What''s the most important design rule across all slides?', '["Each slide should have a completely different color scheme and font", "Maintain consistent colors, fonts, and layout style across all slides so it feels cohesive", "Put all information on the first slide only", "Use as many fonts as possible to keep it interesting"]'::jsonb, 1),
  ('OQ44', 'Open Quiz Q44', 'B', 'A teammate''s poster has excellent content but uses light grey text (#CCCCCC) on a white background (#FFFFFF). What feedback should you give?', '["It looks clean and minimal — keep it", "The contrast is far too low — the text will be nearly invisible, especially in print or on low-brightness screens. Use a darker text color", "Change the background to black", "Remove the text entirely"]'::jsonb, 1),
  ('OQ45', 'Open Quiz Q45', 'C', 'You''re promoting an event with a ₹500 budget. Which combination gives the BEST reach to college students?', '["Newspaper ad and radio spot", "Printed pamphlets distributed at a mall", "Targeted Instagram reels, WhatsApp group broadcasts, and classroom announcements", "A billboard near the campus gate"]'::jsonb, 2),
  ('OQ46', 'Open Quiz Q46', 'C', 'During your event, a sponsor''s representative is unhappy because their logo is smaller than agreed on the main banner. How should you handle it?', '["Ignore the complaint — it''s too late now", "Acknowledge the error, apologize sincerely, and immediately offer alternatives — prominent mentions from stage, extra social media posts, a corrected digital banner display", "Argue that the logo size is fine", "Remove all sponsor logos to be fair"]'::jsonb, 1),
  ('OQ47', 'Open Quiz Q47', 'C', 'Your event starts in 1 hour but the catering hasn''t arrived and isn''t answering calls. What''s the best course of action?', '["Cancel the event", "Inform your team lead immediately, assign someone to keep trying the caterer while others identify a quick backup option (nearby restaurants, quick delivery), and don''t announce the issue to attendees prematurely", "Wait until attendees start complaining", "Publicly post about the catering failure on social media"]'::jsonb, 1),
  ('OQ48', 'Open Quiz Q48', 'C', 'What is the most effective way to collect post-event feedback?', '["Ask attendees verbally while they''re rushing to leave", "Send a short, focused Google Form link within 24 hours of the event — while the experience is still fresh", "Wait 2 months and then ask", "Only collect feedback from sponsors"]'::jsonb, 1),
  ('OQ49', 'Open Quiz Q49', 'C', 'Two members of your organizing committee have a strong disagreement about the event theme, and it''s slowing down all planning. As the lead, what''s the best approach?', '["Let them argue until one gives up", "Listen to both proposals, evaluate them against the event''s objectives and target audience, make a decision, and move forward firmly but respectfully", "Cancel the event", "Change the topic entirely without consulting anyone"]'::jsonb, 1),
  ('OQ50', 'Open Quiz Q50', 'C', 'Your society''s Instagram has 5,000 followers but posts average only 50 likes. What should you investigate?', '["Nothing — 50 likes is great for 5,000 followers", "Delete the account and start over", "Whether the content resonates with the audience, posting times, content format (reels vs static), caption quality, hashtag strategy, and whether the follower base is genuinely interested or inflated", "Simply buy more followers to increase the numbers"]'::jsonb, 2)
) as v(ext, title, sec, body, opts, ci)
on conflict (ext_code) do update
   set question_set = 'open_quiz', title = excluded.title, section = excluded.section,
       body = excluded.body, options = excluded.options, correct_index = excluded.correct_index,
       marks = 1, active = true, round_pool = null;

-- the Open Quiz round uses the same paper size and timer as the recruitment quiz
update quiz.batches set paper_mcq = null, paper_coding = null, pool_no = 0 where name = 'Open Quiz';

-- ---------------------------------------------------------------------
-- The draw. Recruitment rounds (pool 1-4) only ever see recruitment questions.
-- The open quiz (pool 0) draws its MCQs at random from the open-quiz set and
-- its optional coding questions from the recruitment coding bank.
-- ---------------------------------------------------------------------
create or replace function quiz.pick_questions(p_kind text, p_section text, p_pool int,
                                               p_excl int, p_total int)
returns table (id int) language plpgsql security definer set search_path = quiz, public as $$
declare v_ids int[] := '{}';
begin
  if p_pool = 0 then
    return query select q.id from quiz.questions q
                  where q.kind = p_kind and q.active
                    and q.question_set = case when p_kind = 'coding' then 'recruitment' else 'open_quiz' end
                    and (p_section is null or q.section = p_section)
                  order by random() limit p_total;
    return;
  end if;

  if p_pool is not null and p_excl > 0 then
    select array(select q.id from quiz.questions q
                  where q.kind = p_kind and q.active and q.question_set = 'recruitment'
                    and (p_section is null or q.section = p_section)
                    and q.round_pool = p_pool
                  order by random() limit p_excl)
      into v_ids;
  end if;

  select v_ids || array(select q.id from quiz.questions q
                where q.kind = p_kind and q.active and q.question_set = 'recruitment'
                  and (p_section is null or q.section = p_section)
                  and q.round_pool is null
                  and not (q.id = any (v_ids))
                order by random()
                limit greatest(p_total - coalesce(array_length(v_ids, 1), 0), 0))
    into v_ids;

  if coalesce(array_length(v_ids, 1), 0) < p_total then
    select v_ids || array(select q.id from quiz.questions q
                  where q.kind = p_kind and q.active and q.question_set = 'recruitment'
                    and (p_section is null or q.section = p_section)
                    and not (q.id = any (v_ids))
                  order by random()
                  limit p_total - coalesce(array_length(v_ids, 1), 0))
      into v_ids;
  end if;

  return query select unnest(v_ids);
end $$;

-- ---------------------------------------------------------------------
-- Instructions before sign-in, for the page the visitor is on.
-- p_round: null / 'Open Quiz' = the open quiz page; 'recruitment' = recruitment page.
-- ---------------------------------------------------------------------
drop function if exists public.exam_info();
create or replace function public.exam_info(p_round text default null)
returns json language sql stable security definer set search_path = quiz, public as $$
  select json_build_object(
    'exam_title',       c.exam_title,
    'mcq_count',        coalesce(b.paper_mcq, c.mcq_count),
    'coding_count',     coalesce(b.paper_coding, c.coding_count),
    'duration_minutes', coalesce(b.duration_minutes, c.duration_minutes),
    'max_flags',        c.max_flags,
    'require_camera',   c.require_camera,
    'require_mic',      c.require_mic)
  from quiz.config c
  left join quiz.batches b
         on b.name = 'Open Quiz' and coalesce(p_round, 'Open Quiz') = 'Open Quiz'
  where c.id = 1;
$$;
grant execute on function public.exam_info(text) to anon, authenticated;

select 'open quiz paper' as step, section, count(*) as questions
  from quiz.questions where question_set = 'open_quiz' and active
 group by section order by section;
