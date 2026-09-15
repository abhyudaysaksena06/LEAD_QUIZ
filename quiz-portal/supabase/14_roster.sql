-- =====================================================================
-- LEAD Quiz Portal — 14: student roster (allowlist for Google sign-in)
--   Batch 1 -> Round 1 (60)   Batch 2 -> Round 2 (59)   Batch 3 -> Round 3 (46)
--   165 unique students. Only these Google accounts can sign in.
--
-- Cleaned before import:
--   * two mistyped addresses corrected (bgarg1_be26@gmail.com,
--     ssharma15_be26@thapar.edu)
--   * duplicate entries removed — one row per person
--   * roll numbers only kept where they are a real 10-digit roll; the
--     spreadsheet's 9.18E+11 values and rows where a phone number was pasted
--     into the roll column are left blank. Roll is a pre-fill hint only —
--     the student types their own at registration and that is what counts.
--   * phone numbers are not imported at all.
--
-- Safe to re-run: existing rows are re-pointed at the right round; a student
-- who has already registered keeps their registration (claimed_by untouched).
-- =====================================================================

do $$
declare v1 int; v2 int; v3 int;
begin
  select id into v1 from quiz.batches where name = 'Round 1';
  select id into v2 from quiz.batches where name = 'Round 2';
  select id into v3 from quiz.batches where name = 'Round 3';
  if v1 is null or v2 is null or v3 is null then
    raise exception 'Rounds not found — run 09_rounds.sql first';
  end if;

  -- clear the mistyped addresses if an earlier run of this file loaded them
  delete from quiz.allowlist
   where email in ('bgarg1_be26@gmailcom', 'ssharma15_be26@thpar.edu')
     and claimed_by is null;
  update quiz.allowlist set email = 'bgarg1_be26@gmail.com'
   where email = 'bgarg1_be26@gmailcom';
  update quiz.allowlist set email = 'ssharma15_be26@thapar.edu'
   where email = 'ssharma15_be26@thpar.edu';

  -- and the duplicate person, if they were never claimed
  delete from quiz.allowlist
   where email in ('vvrinda_26@thapar.edu') and claimed_by is null;

  insert into quiz.allowlist (email, batch_id, full_name, roll_hint) values
    ('aabhapahuja612@gmail.com', v1, 'Aabha Pahuja', '1026030403'),
    ('nnandita_be26@thapar.edu', v1, 'Nandita', null),
    ('gandhitushar5628@gmail.com', v1, 'Tushar Gandhi', '1026250221'),
    ('ugrover_be26@thapar.edu', v1, 'Uttkarsh Grover', null),
    ('agoyal6_be25@thapar.edu', v1, 'Ananya', '1025060221'),
    ('gsharma4_be26@thapar.edu', v1, 'Gloria Sharma', '1026030019'),
    ('jjapjot_blas26@gmail.com', v1, 'Japjot', '1426000013'),
    ('vgoyal4_be26@thapar.edu', v1, 'Vivaan GOYAL', '1026060002'),
    ('vn07042009@gmail.com', v1, 'Kritika Garg', '1026250250'),
    ('hbhardwaj_be26@thapar.edu', v1, 'Harshil bhardwaj', '1026030061'),
    ('ssengar_be26@thapar.edu', v1, 'Shivam sengar', '1026030893'),
    ('sgarg8_be26@thapar.edu', v1, 'Shiney Garg', '1026030828'),
    ('psingh8_be26@thapar.edu', v1, 'Priyanshi Singh', '1026220060'),
    ('ygoyal1_be26@gmail.com', v1, 'yachika goyal', '1026210035'),
    ('aaaditya_be26@thapar.edu', v1, 'Aaditya Panghal', '1026030491'),
    ('ijain_be26@thapar.edu', v1, 'Ishaan Jain', '1026030105'),
    ('ameel_be26@thapar.edu', v1, 'Aditya Singh Meel', '1026170170'),
    ('apandey2_be26@thapar.edu', v1, 'Ayush Pandey', '1026030588'),
    ('vjain1_be26@thapar.edu', v1, 'Vidit Jain', '1026030122'),
    ('abawa1_be26@thapar.edu', v1, 'Atharv Bawa', '1026030727'),
    ('jkumar_be26@thapar.edu', v1, 'Jashan kumar kansal', '1026170106'),
    ('jchilkoti_be26@thapar.edu', v1, 'Jayant Chilkoti', '1026190014'),
    ('aagarwal7_be26@thapar.edu', v1, 'Ansh Agarwal', '1026060047'),
    ('hjain1_be26@thapar.edu', v1, 'Hardik Jain', '1026220091'),
    ('vbansal1_be26@thapar.edu', v1, 'Vansh Bansal', '1026030163'),
    ('nsoni_be26@thapar.edu', v1, 'Nilay soni', '1026250081'),
    ('jkhurana_be26@thapar.edu', v1, 'Jasleen Kaur Khurana', '1026090009'),
    ('sbatth_be26@thapar.edu', v1, 'Sukhmanveer singh batth', '1026230069'),
    ('aditya2007cool@gmail.com', v1, 'Aditya verma', '1026150180'),
    ('kkrishika_be26@thapar.edu', v1, 'Krishika', '1026150157'),
    ('aangel1_be26@thapar.edu', v1, 'Angel Garg', '1026030974'),
    ('skumar8_be26@thapar.edu', v1, 'Suvansh Kumar', '1026030225'),
    ('agoyal_be26@thapar.edu', v1, 'Aadil Goyal', '1026150166'),
    ('pnautiyal_be26@thapar.edu', v1, 'Pragyan Nautiyal', '1026060093'),
    ('mmahajan3_be26@gmail.com', v1, 'Mihir Mahajan', '1026030541'),
    ('ssimone_be26@thapar.edu', v1, 'Simone', '1026190059'),
    ('sgupta11_be26@thapar.edu', v1, 'Shaurya Gupta', '1026170072'),
    ('mchawla_be26@thapar.edu', v1, 'Mishita chawla', '1026150321'),
    ('vvanshika1_be26@thapar.edu', v1, 'Vanshika', '1026150393'),
    ('ngarg5_be26@thapar.edu', v1, 'Navya garg', '1026030871'),
    ('dbhandari_be26@thapar.edu', v1, 'Daksh Bhandari', '1026030749'),
    ('ssharma26_be26@thapar.edu', v1, 'Sarthakk Sharma', '1026150361'),
    ('rkapur_be27@thapar.edu', v1, 'Ritwik Kapur', '1026090050'),
    ('gkaur6_be26@thapar.edu', v1, 'Gurpriya Kaur', '1026170540'),
    ('tkhosla_be26@thapar.edu', v1, 'Tejas Khosla', '1026170150'),
    ('gchhina_be26@thapar.edu', v1, 'Gurnoor Kaur Chhina', '1026150250'),
    ('gthakur_be26@thapar.edu', v1, 'Gauri Thakur', '1026150123'),
    ('pbhola_be26@gmail.com', v1, 'Piyush Bhola', '1026250029'),
    ('cgambhir_be26@thapar.edu', v1, 'Chahat Gambhir', '1026030521'),
    ('mgoel_be26@thapar.edu', v1, 'Mishthi goel', '1026170333'),
    ('dgupta_be26@thapar.edu', v1, 'Daksh Gupta', null),
    ('kharshit_be26@thapar.edu', v1, 'Kumar Harshit', '1026170173'),
    ('amor_be26@thapar.edu', v1, 'Aryan', '1026030781'),
    ('nsingla1_be26@thapar.edu', v1, 'Nandiika Singla', '1026050138'),
    ('egill_be26@thapar.edu', v1, 'EKJOT GILL', '1026040143'),
    ('aarnav_be26@thapar.edu', v1, 'ARNAV', '1026030043'),
    ('nvijh_be26@thapar.edu', v1, 'Namya Vijh', '1026250191'),
    ('ssakshi_be26@thapar.edu', v1, 'Sakshi', '1026250028'),
    ('hkumar1_be26@thapar.edu', v1, 'Hiten Kumar', '1026030730'),
    ('raditya_bbamba26@thapar.edu', v1, 'RENDUCHINTALA VARSHITH ADITYA', '5526000013'),
    ('ssingh33_be26@thapar.edu', v2, 'Siddharth singh', '1026030395'),
    ('gkamra_be26@thapar.edu', v2, 'gaurish kamra', '1026250035'),
    ('kbhardwaj1_be26@thapar.edu', v2, 'Kshitij Bhardwaj', '1026030285'),
    ('sjain3_be25@thapar.edu', v2, 'Sambhav jain', '1025220092'),
    ('nkaur_be26@thapar.edu', v2, 'Nyamat kaur', '1026030096'),
    ('hdogra_be26@thapar.edu', v2, 'Hardik Dogra', '1026030540'),
    ('jjahnavi_be26@thapar.edu', v2, 'Jahnavi', '1026170176'),
    ('dyadav_1be26@thapar.edu', v2, 'Divyansh Yadav', '1026190113'),
    ('agupta14_be26@gmail.com', v2, 'Anvi', '1026030480'),
    ('bhav.kanu2000@gmail.com', v2, 'BHAVISHYA KUMAR', '1026060038'),
    ('msekhon_be26@thapar.edu', v2, 'MEHAR KAUR SEKHON', '1026030415'),
    ('gbansal_be26@thapar.edu', v2, 'Gunishka bansal', '1026030878'),
    ('bgarg1_be26@gmail.com', v2, 'Bhavya Garg', '1026250199'),
    ('mmadhavi_be26@thapar.edu', v2, 'Madhavi', '1026170054'),
    ('ssabhaarwal_be26@thapar.edu', v2, 'Sabina Sabharwal', '1026030447'),
    ('mkaur4_be26@thapar.edu', v2, 'Mehraj kaur', '1026250200'),
    ('pupadhyay_be26@thapar.edu', v2, 'Pratiksha Upadhyay', '1026030103'),
    ('sshreya_be26@thapar.edu', v2, 'Shreya', '1026170415'),
    ('kballing_be26@thapar.edu', v2, 'Karandeep Singh Balling', '1026250154'),
    ('jsingh21_be26@thapar.edu', v2, 'Jasman Singh', '1026030248'),
    ('aasmi_be26@thapar.edu', v2, 'Asmi', '1026030027'),
    ('mgangwal_be26@thapar.edu', v2, 'Mohit Gangwal', '1026170426'),
    ('gayatria418@gmail.com', v2, 'Gayatri Aggarwal', '1026060157'),
    ('rriya_be26@thapar.edu', v2, 'Riya', '1026150022'),
    ('hkhator_be26@thapar.edu', v2, 'Harshita Khator', '1026060150'),
    ('mgoel1_be26@thapar.edu', v2, 'Mudita Goel', '1026230012'),
    ('pchadha_be26@thapar.edu', v2, 'Prannav Chadha', '1026030666'),
    ('rpoonia_be26@thapar.edu', v2, 'Ryan poonia', '1026030442'),
    ('dchhabra_be26@thapar.edu', v2, 'Dhairya Chhabra', '1026060083'),
    ('gmahay_be26@thapar.edu', v2, 'Guntas Singh Mahay', null),
    ('skaur_be26@thapar.edu', v2, 'Savreen Kaur', '1026250045'),
    ('tsingla1_be26@thapar.edu', v2, 'Tanshiv Singla', '1026030932'),
    ('ljindal_be26@thapar.edu', v2, 'Latisha Jindal', '1026250012'),
    ('ndesai_be26@thapar.edu', v2, 'Nikhil Desai', '1026170360'),
    ('djain4_be@thapar.edu', v2, 'Dhruvika Jain', '1026060067'),
    ('dmalhotra_be26@thapar.edu', v2, 'Devish Malhotra', '1026030250'),
    ('dhananjaygarg739@gmail.com', v2, 'Dhananjay Garg', null),
    ('vvrinda_be26@thapar.edu', v2, 'Vrinda', '1026170327'),
    ('ijairath_be26@thapar.edu', v2, 'Inayat Jairath', '1026030980'),
    ('rsaini1_be26@thapar.edu', v2, 'Raghav Saini', '1026190065'),
    ('rgahlawat_be26@thapar.edu', v2, 'ROHINESH GAHLAWAT', '1026150119'),
    ('akohli_be26@thapar.edu', v2, 'Akul Kohli', null),
    ('kdhand_be26@thapar.edu', v2, 'Krishi Dhand', '1026190012'),
    ('agarg14_be26@thapar.edu', v2, 'Akshra', '1026170212'),
    ('yyatharth1_26@thapar.edu', v2, 'Yatharth', '1026040104'),
    ('rishabhagarwal1994@gmail.com', v2, 'Rishabh Agarwal', '1026030603'),
    ('mkaur13_be26@thapar.edu', v2, 'Mandeep Kaur', '1026030162'),
    ('divgunkaur14@gmail.com', v2, 'Divgun kaur', '1026030185'),
    ('akaistha_be26@thapar.edu', v2, 'Aanya Kaistha', '1026030987'),
    ('ssharma3_be26@thapar.edu', v2, 'Snigdha sharma', '1026150362'),
    ('asinghal_be26@thapar.edu', v2, 'Anwesh Singhal', '1026250058'),
    ('msingla_be26@thapar.edu', v2, 'Moksh singla', '1026170336'),
    ('rkundal_be26@thapar.edu', v2, 'Riddhiman Kundal', '1026030151'),
    ('dsingla3_be26@thapar.edu', v2, 'Disha Singla', '1026170185'),
    ('vsondhi_be26@thapar.edu', v2, 'Viraj sondhi', '1026030353'),
    ('jjhanvi_be26@thapar.edu', v2, 'Jhanvi', '1026030057'),
    ('esingh2_be26@thapar.edu', v2, 'Ekamvir Singh', '1026170504'),
    ('ychauhan_be26@thapar.edu', v2, 'Yashwardhan Singh Chauhan', '1026170080'),
    ('avaid_be26@thapar.edu', v2, 'Anya vaid', '1026180056'),
    ('nchawla1_be26@thapar.edu', v3, 'Nikhil Chawla', '1206030157'),
    ('mbansal_be26@thapar.edu', v3, 'MADHAV BANSAL', '1026170122'),
    ('ebhardwaj_be26@thapar.edu', v3, 'Ehsaas Bhardwaj', '1026030369'),
    ('asharma36_be26@thapar.edu', v3, 'Asmita Sharma', '1026150010'),
    ('dprothia_be26@thapar.edu', v3, 'Devansh Prothia', '1026090012'),
    ('arana4_be26@thapar.edu', v3, 'Aryan Rana', '1026150247'),
    ('sbhattacharya_be26@thapar.edu', v3, 'SHREYAS BHATTACHARYA', '1026030086'),
    ('bjha_be26@thapar.edu', v3, 'Bhavya Jha', '1026170123'),
    ('kgarg6_be26@thapar.edu', v3, 'Kushal Garg', '1026030921'),
    ('rdhannani_be26@thapar.edu', v3, 'Ronak dhannani', '1026170178'),
    ('dmohindru_be26@thapar.edu', v3, 'Divija Mohindru', '1026150267'),
    ('averma12_be26@thapar.edu', v3, 'Agrata Verma', '1026170536'),
    ('skumar3_be26@thapar.edu', v3, 'Saksham Kumar', '1026030929'),
    ('aagrawal1_be26@thapar.edu', v3, 'Aashi Agrawal', '1026030358'),
    ('gsakhuja_be25@thapar.edu', v3, 'Gaurang', '1025210018'),
    ('graheja_be26@thapar.edu', v3, 'Girisha Raheja', '1026170174'),
    ('pmahajan_be26@thapar.edu', v3, 'Pujya mahajan', '1026030975'),
    ('ajha1_be26@thapar.edu', v3, 'AJ', '1026040098'),
    ('akoundal_be26@thapar.edu', v3, 'Arnav Koundal', '1026170279'),
    ('pkataria_be26@thapar.edu', v3, 'Pearl Kataria', '1026030409'),
    ('dishita312008@gmail.com', v3, 'dishita gupta', '1026030302'),
    ('ksingh1_be26@thapar.edu', v3, 'Keerti Singh', '1026230009'),
    ('vgoel1_be26@thapar.edu', v3, 'Vivan Goel', '1026090004'),
    ('grovertanvi08@gmail.com', v3, 'Tanvi Grover', '1026170520'),
    ('jhanvinain14@gmail.com', v3, 'Jhanvi', null),
    ('sgupta18_be26@thapar.edu', v3, 'Siddhant Gupta', '1026030894'),
    ('aagarwal10_be26@thapar.edu', v3, 'Ankita Agarwal', '1026250087'),
    ('vaibhavi.v109@gmail.com', v3, 'Vaibhavi Verma', '1026250119'),
    ('ssrishty_be26@thapar.edu', v3, 'srishty', '1026250053'),
    ('pprisha_be26@thapar.edu', v3, 'PRISHA', '1026080073'),
    ('kbiswas_be26@thapar.edu', v3, 'Kaushiki Biswas', '1026170141'),
    ('abhardwaj_be26@thapar.edu', v3, 'Aditya Bhardwaj', '1026170223'),
    ('ddivyam_be26@thapar.edu', v3, 'Divyam', '1026030712'),
    ('smishra2_be26@thapar.edu', v3, 'Shaurya Mishra', '1026030846'),
    ('pagrahari_be26@thapar.edu', v3, 'PRANEY AGRAHARI', '1026250136'),
    ('bhavyakhandelwal637@gmail.com', v3, 'Bhavya Khandelwal', '1026150300'),
    ('ssarin_be26@thapar.edu', v3, 'Shivangini Sarin', '1026170066'),
    ('pojha_be26@thapar.edu', v3, 'Piyush Raj Ojha', '1026150238'),
    ('sratna_be26@thapar.edu', v3, 'Shambhav Ratna', '1026170097'),
    ('bansalkhushi232@gmail.com', v3, 'Khushi Bansal', '1026030452'),
    ('bmittal_be26@thapar.edu', v3, 'Bhavi Mittal', '1026030977'),
    ('ssaxena_be26@thapar.edu', v3, 'Shivangi Saxena', '1026030150'),
    ('ssharma15_be26@thapar.edu', v3, 'Saksham Sharma', '1026003052'),
    ('rridhi_be26@thapar.edu', v3, 'Ridhi', '1026170265'),
    ('dmittal3_be26@thapar.edu', v3, 'Devangi Mittal', '1026060099'),
    ('lhanda_be26@thapar.edu', v3, 'Lavya Handa', '1026250083')
  on conflict (email) do update
     set batch_id  = excluded.batch_id,
         full_name = coalesce(excluded.full_name, quiz.allowlist.full_name),
         roll_hint = excluded.roll_hint;

  -- a student who registered before their round was known gets placed now.
  -- Anyone an admin has deliberately moved (e.g. to Backup) is left alone.
  update quiz.students s
     set batch_id = a.batch_id
    from quiz.allowlist a
   where a.claimed_by = s.roll_no and a.batch_id is not null and s.batch_id is null;
end $$;

select 'roster' as step, b.name as round, count(*) as allowlisted,
       count(a.claimed_by) as registered,
       count(a.roll_hint)  as with_roll_hint
  from quiz.allowlist a join quiz.batches b on b.id = a.batch_id
 group by b.name order by b.name;

-- every address should be a real thapar.edu or gmail.com address; this must return no rows
select 'check this address' as step, a.email, b.name as round, a.full_name
  from quiz.allowlist a left join quiz.batches b on b.id = a.batch_id
 where a.email !~ '^[^@]+@(thapar\.edu|gmail\.com)$'
 order by a.email;
