# Seeds one fully-populated demo account: six weeks of planning, the five behind the current week
# finished and summarised, the current one still in flight.
#
#   bin/rails runner script/seed_demo_account.rb
#
# Safe to re-run. Everything the account owns is torn down and rebuilt from the tables below --
# except the AI weekly summaries, which are lifted out before the wipe and put back afterwards. A
# summary is written once per week and never regenerated (see WeeklySummary), and the key this runs
# on is on the Gemini free tier at five requests a minute, so re-running should not spend five of
# them on reflections that have not changed.
#
# Local only, for the same reason db/seeds.rb is: nothing at runtime grants a subscription outside
# Stripe's webhook, so an account like this can only be made here.
abort "Refusing to run outside development or test." unless Rails.env.local?

EMAIL = "tmanistoopro@gmail.com".freeze
USERNAME = "tmanistoopro".freeze
PASSWORD = "220204Th#".freeze

# Six Mondays ending at the week the user is standing in. Derived rather than hardcoded so the
# account is still "five finished weeks and a live one" whenever this is run.
CURRENT_WEEK = Date.current.beginning_of_week
WEEK_STARTS = (0..5).map { |i| CURRENT_WEEK - (5 - i) * 7 }

ROLES = {
  student: { role_name: "Student", icon_id: "graduation", color_id: "secondary" },
  engineer: { role_name: "Part-Time Software Engineer", icon_id: "briefcase", color_id: "teal" }
}.freeze

# The standing Sharpen the Saw library. A week selects from it rather than owning copies, so these
# rows outlive every plan below.
ACTIVITIES = {
  gym: { dimension: "physical", activity_description: "Gym — push/pull session" },
  run: { dimension: "physical", activity_description: "Evening 5K along the canal" },
  read: { dimension: "mental", activity_description: "Read 20 pages of Designing Data-Intensive Applications" },
  leet: { dimension: "mental", activity_description: "One medium LeetCode problem" },
  journal: { dimension: "spiritual", activity_description: "Morning journaling, ten minutes" },
  reset: { dimension: "spiritual", activity_description: "Sunday reset and week review" },
  home: { dimension: "social", activity_description: "Call home" },
  friends: { dimension: "social", activity_description: "Board games with the housemates" }
}.freeze

# One week's shape, in day-then-time order. `:work` and `:study` slots are filled from the week's
# goals below; `:sts` names a library activity, or `:mental`/`:social` for the slot whose activity
# varies week to week. Times do not overlap, so every calendar in the app draws a clean grid.
TEMPLATE = [
  { day: 0, from: "07:00", to: "07:20", kind: :sts, key: :journal },
  { day: 0, from: "09:15", to: "09:30", kind: :fixed, name: "Standup — Orbit team" },
  { day: 0, from: "09:45", to: "12:00", kind: :work },
  { day: 0, from: "13:30", to: "15:30", kind: :study },
  { day: 0, from: "18:30", to: "19:30", kind: :sts, key: :gym },
  { day: 1, from: "10:00", to: "12:00", kind: :fixed, name: "Distributed Systems lecture" },
  { day: 1, from: "13:00", to: "15:00", kind: :study },
  { day: 1, from: "15:30", to: "17:30", kind: :work },
  { day: 1, from: "20:00", to: "20:45", kind: :sts, key: :mental },
  { day: 2, from: "09:15", to: "09:30", kind: :fixed, name: "Standup — Orbit team" },
  { day: 2, from: "09:45", to: "12:00", kind: :work },
  { day: 2, from: "15:00", to: "15:30", kind: :fixed, name: "FYP supervisor meeting" },
  { day: 2, from: "16:00", to: "18:00", kind: :study },
  { day: 2, from: "19:00", to: "20:00", kind: :sts, key: :run },
  { day: 3, from: "09:00", to: "11:00", kind: :work },
  { day: 3, from: "14:00", to: "16:00", kind: :fixed, name: "Machine Learning lab" },
  { day: 3, from: "16:30", to: "18:30", kind: :study },
  { day: 3, from: "20:00", to: "21:00", kind: :sts, key: :social },
  { day: 4, from: "09:15", to: "09:30", kind: :fixed, name: "Standup — Orbit team" },
  { day: 4, from: "09:45", to: "12:00", kind: :work },
  { day: 4, from: "13:00", to: "14:30", kind: :work },
  { day: 4, from: "16:00", to: "17:00", kind: :fixed, name: "Sprint review — Orbit" },
  { day: 4, from: "18:30", to: "19:30", kind: :sts, key: :gym },
  { day: 5, from: "10:00", to: "12:30", kind: :study },
  { day: 5, from: "19:00", to: "21:00", kind: :sts, key: :social },
  { day: 6, from: "10:00", to: "12:00", kind: :study },
  { day: 6, from: "15:00", to: "16:00", kind: :sts, key: :reset },
  { day: 6, from: "17:00", to: "18:30", kind: :study }
].freeze

# The day of each week whose first goal-backed task is starred. A daily priority is the task's own
# claim on its day, unlike the weekly priority that rides on the goal, so it moves around.
PRIORITY_DAYS = [
  [ 0, 1, 2, 4, 6 ],
  [ 0, 1, 2, 3, 5 ],
  [ 0, 2, 3, 4, 6 ],
  [ 0, 1, 3, 4, 5 ],
  [ 1, 2, 3, 4, 6 ],
  [ 0, 1, 2, 3, 4 ]
].freeze

# The six weeks, oldest first.
#
# Each week supplies exactly seven `:study` tasks (from the Student goals, in order) and six
# `:work` ones (from the Part-Time Software Engineer goals), which is what the template above has
# room for. `achieved:` decides completion rather than a dice roll, because Goal#achieved is "every
# task on it was ticked off" -- a rate applied blindly would make the achievement figures on
# /history and /analytics an accident.
WEEKS = [
  {
    activities: %i[gym run read journal reset home],
    picks: { mental: :read, social: :home },
    goals: [
      { id: :s1, role: :student, text: "Finish the FYP literature review draft",
        priority: true, achieved: false, missed: 2,
        tasks: [ "Read and annotate six survey papers",
                 "Draft the lit review outline",
                 "Write the lit review — habit-tracking section",
                 "Write the lit review — gamification section" ] },
      { id: :s2, role: :student, text: "Complete Distributed Systems assignment 1",
        achieved: true,
        tasks: [ "DS assignment 1 — implement Raft leader election",
                 "DS assignment 1 — build the test harness",
                 "DS assignment 1 — write up and submit" ] },
      { id: :e1, role: :engineer, text: "Ship HAB-212: retry failed checkout webhooks",
        achieved: true,
        tasks: [ "HAB-212 — reproduce the webhook failure",
                 "HAB-212 — add the retry queue",
                 "HAB-212 — integration test for the retry path",
                 "HAB-212 — address review comments" ] },
      { id: :e2, role: :engineer, text: "Cut the Orbit billing test suite under five minutes",
        achieved: false, missed: 1,
        tasks: [ "Profile the Orbit billing suite",
                 "Parallelise the billing specs" ] }
    ],
    reflections: [
      "Got the retry queue for HAB-212 roughed out before lunch, which felt good, but the afternoon lit review block turned into three hours of skim-reading papers I have already read. I keep opening the same six PDFs instead of writing anything.",
      "Lecture was dense, and the Raft section only clicked once I drew the leader election out on paper. Assignment 1 is genuinely fun. Did not touch the lit review at all today and I am aware that I am avoiding it.",
      "Supervisor meeting went better than I expected. She said the draft does not need to be good, it needs to exist. I wrote 400 words straight afterwards and it was the easiest writing I have done all week.",
      "Slow day. Spent the whole work block cleaning up review comments on HAB-212 rather than doing anything new. The call home in the evening was the best part of it.",
      "HAB-212 is merged. Profiled the billing suite afterwards: eleven minutes, and most of that is one file. Sprint review was fine. Skipped the gym because I was tired, which is becoming a Friday thing.",
      "Two and a half hours on the DS assignment and leader election is passing its tests now. Board games with the housemates in the evening. Barely thought about the lit review, which is the one thing left over.",
      "Submitted DS assignment 1, so that is a whole thing off the pile. The week review made it obvious: everything with a deadline got done and everything without one — the lit review, the test suite — did not move at all."
    ]
  },
  {
    activities: %i[gym run leet journal reset friends],
    picks: { mental: :leet, social: :friends },
    goals: [
      { id: :s1, role: :student, text: "Finish the FYP literature review draft",
        priority: true, achieved: true, carried_from: [ 0, :s1 ],
        tasks: [ "Rewrite the lit review — gamification section",
                 "Build the comparison table",
                 "Proofread and hand the draft to my supervisor" ] },
      { id: :s2, role: :student, text: "Revise for the Machine Learning midterm",
        achieved: true,
        tasks: [ "ML revision — regularisation and SVMs",
                 "ML revision — past paper 2024",
                 "ML revision — past paper 2025",
                 "ML midterm — final skim of the lecture notes" ] },
      { id: :e1, role: :engineer, text: "Cut the Orbit billing test suite under five minutes",
        achieved: true, carried_from: [ 0, :e2 ],
        tasks: [ "Parallelise the billing specs",
                 "Cache the Stripe fixtures",
                 "Drop the sleep-based waits" ] },
      { id: :e2, role: :engineer, text: "Ship HAB-231: invoice PDF export",
        achieved: false, missed: 1,
        tasks: [ "HAB-231 — spike the PDF renderer",
                 "HAB-231 — template the invoice layout",
                 "HAB-231 — wire the download endpoint" ] }
    ],
    reflections: [
      "Started the week by rewriting the gamification section instead of reading more, which is what my supervisor has been telling me to do since day one. Nine hundred words. Rough, but on the page.",
      "Built the comparison table for the lit review and it took the whole afternoon, but it is the clearest thing in the draft now. Parallelising the billing specs took the suite from eleven minutes to six.",
      "Proofread the draft and handed it over. That is the goal I carried in from last week finally closed. Supervisor only had structural comments this time, no go-read-more.",
      "Past paper 2024 went badly, 58%. Spent the evening going back over SVMs rather than sulking about it. Cached the Stripe fixtures at work and the suite is under five minutes now.",
      "Started the HAB-231 PDF spike, which is fiddlier than it looked, and got the invoice layout templated. Skipped the gym. That is three Fridays running.",
      "Past paper 2025, 74%. The whole difference was doing it timed with the notes shut. The housemates dragged me out in the evening and I am glad they did.",
      "Skimmed the lecture notes and called it a week. Same lesson as last week, really: the things I carried over only moved once I stopped preparing for them and started producing something."
    ]
  },
  {
    activities: %i[gym run read journal reset home],
    picks: { mental: :read, social: :home },
    goals: [
      { id: :s1, role: :student, text: "Submit the FYP interim report",
        priority: true, achieved: true,
        tasks: [ "Interim report — methodology chapter",
                 "Interim report — evaluation plan",
                 "Interim report — figures and formatting",
                 "Interim report — final read and submit" ] },
      { id: :s2, role: :student, text: "Finish Distributed Systems assignment 2",
        achieved: false, missed: 2,
        tasks: [ "DS assignment 2 — read the spec properly",
                 "DS assignment 2 — design the consistency model",
                 "DS assignment 2 — scaffold the repo" ] },
      # Dropped mid-week, and deliberately left with no tasks: /history reports it as given up on,
      # and /analytics counts it in the dropped column rather than the denominator.
      { id: :s3, role: :student, text: "Get ahead on the HCI reading list",
        dropped: true, tasks: [] },
      { id: :e1, role: :engineer, text: "Ship HAB-231: invoice PDF export",
        achieved: true, carried_from: [ 1, :e2 ],
        tasks: [ "HAB-231 — fix the page-break bug",
                 "HAB-231 — add the VAT line",
                 "HAB-231 — ship behind a flag" ] },
      { id: :e2, role: :engineer, text: "Take the on-call handover for Orbit",
        achieved: true,
        tasks: [ "Read the Orbit runbook end to end",
                 "Shadow Thursday's on-call rotation",
                 "Write up the alert triage notes" ] }
    ],
    reflections: [
      "Methodology chapter, straight through the morning block. Writing is so much easier now that the lit review actually exists. The HAB-231 page-break bug took the entire work block and I still do not fully understand the fix.",
      "Lecture, then the evaluation plan section. Read the Orbit runbook cover to cover — I have been on-call adjacent for two months without knowing what half of those alerts even mean.",
      "Figures and formatting for the report. Supervisor signed off on the structure. Added the VAT line to the invoice PDF, which was a two-line change that took an hour to test properly.",
      "Shadowed the on-call rotation and nothing broke, which was both a relief and a waste of an afternoon. Gave up on the HCI reading list goal — it was never going to happen this week and pretending otherwise was costing me somewhere else.",
      "Submitted the interim report. Shipped HAB-231 behind a flag. Best Friday I have had this month by a distance.",
      "Read the DS assignment 2 spec properly. It is a lot bigger than assignment 1. Did not start any of it, just sat with how big it is.",
      "Designed the consistency model on paper and scaffolded the repo, then stopped. Looking back at the week, dropping the reading list goal on Thursday is the reason everything else landed."
    ]
  },
  {
    activities: %i[gym run leet journal reset friends],
    picks: { mental: :leet, social: :friends },
    goals: [
      { id: :s1, role: :student, text: "Finish Distributed Systems assignment 2",
        achieved: true, carried_from: [ 2, :s2 ],
        tasks: [ "DS assignment 2 — implement the replication log",
                 "DS assignment 2 — failure injection tests",
                 "DS assignment 2 — benchmark and write up",
                 "DS assignment 2 — submit" ] },
      { id: :s2, role: :student, text: "Prepare the FYP supervisor demo",
        priority: true, achieved: true,
        tasks: [ "Demo — script the walkthrough",
                 "Demo — seed a realistic dataset",
                 "Demo — dry run with a coursemate" ] },
      { id: :e1, role: :engineer, text: "Ship HAB-247: usage-based billing rollup",
        achieved: false, missed: 1,
        tasks: [ "HAB-247 — model the rollup table",
                 "HAB-247 — write the backfill script",
                 "HAB-247 — hourly aggregation job" ] },
      { id: :e2, role: :engineer, text: "Clear the Atlas dashboard bug backlog",
        achieved: true,
        tasks: [ "ATL-118 — timezone off-by-one on the weekly chart",
                 "ATL-121 — empty state for a new workspace",
                 "ATL-124 — focus trap in the export modal" ] }
    ],
    reflections: [
      "Replication log implementation took most of the day and it was the good kind of hard. Modelled the HAB-247 rollup table at work — the schema is the easy part, the backfill is going to be the problem.",
      "Failure injection tests found two real bugs in my own code, which is exactly what they are for. The demo script for the supervisor is about half written.",
      "Benchmarked the assignment and wrote it up. The supervisor meeting turned into the demo dry run and she asked for a realistic dataset rather than my three rows of test data.",
      "Seeded the demo dataset properly. The HAB-247 backfill script is written but I do not trust it at production volumes. Three Atlas bugs cleared, all small ones.",
      "Submitted DS assignment 2. Dry-ran the demo with a coursemate and it fell apart on the third step, which is much better happening now than on Monday.",
      "Fixed the demo walkthrough so it survives someone clicking the wrong thing. Quiet day otherwise, which I needed.",
      "Demo is solid now. HAB-247 is the one thing unfinished — the hourly aggregation job is untouched and I have been avoiding it all week the same way I avoided the lit review back in the first week."
    ]
  },
  {
    activities: %i[gym run read journal reset home],
    picks: { mental: :read, social: :home },
    goals: [
      { id: :s1, role: :student, text: "Build the FYP evaluation dataset",
        priority: true, achieved: true,
        tasks: [ "Recruit six participants",
                 "Draft the consent form and brief",
                 "Build the task scripts",
                 "Pilot the study with one participant" ] },
      { id: :s2, role: :student, text: "Write up the HCI group project report",
        achieved: false, missed: 2,
        tasks: [ "HCI report — related work",
                 "HCI report — study design section",
                 "HCI report — merge everyone's sections" ] },
      { id: :e1, role: :engineer, text: "Ship HAB-247: usage-based billing rollup",
        achieved: true, carried_from: [ 3, :e1 ],
        tasks: [ "HAB-247 — hourly aggregation job",
                 "HAB-247 — wire the rollup into the dashboard",
                 "HAB-247 — load test the backfill" ] },
      { id: :e2, role: :engineer, text: "Write the Orbit incident postmortem",
        achieved: true,
        tasks: [ "Postmortem — build the timeline",
                 "Postmortem — contributing factors",
                 "Postmortem — agree the action items" ] }
    ],
    reflections: [
      "Recruitment emails out to eight people and six had said yes by the evening, which is more than I expected. Finally wrote the hourly aggregation job I had been dodging since last Wednesday.",
      "Consent form and brief drafted. Dry work, but done. Wired the rollup into the dashboard and the numbers matched the old report first time, which almost never happens.",
      "Built the task scripts for the study. Supervisor meeting was short and useful. Load-tested the backfill and it held, so that is one less thing to worry about on Friday.",
      "Pilot session with one participant. Two of my tasks were badly worded and I would never have caught that without the pilot. Started the postmortem timeline in the evening.",
      "HAB-247 shipped, which is the goal I carried in from last week. Postmortem contributing factors written with the team. Genuinely good Friday.",
      "HCI report related work section. The group is behind and I am doing more than my share of it, which I should probably say something about rather than just quietly absorbing.",
      "Merged everyone's HCI sections and it reads like four different people wrote it, because it was. My study design section still is not written. The pattern this week is that anything with another person attached to it moved, and the solo writing did not."
    ]
  },
  {
    activities: %i[gym run read journal reset home friends],
    picks: { mental: :read, social: :home },
    live: true,
    # The night the check-in was answered "not tonight", which is the one thing only check_ins can
    # record -- so this day deliberately has no reflection either.
    skipped_day: 3,
    goals: [
      { id: :s1, role: :student, text: "Run the FYP user study",
        priority: true,
        tasks: [ "Study sessions — participants 1 and 2",
                 "Study sessions — participants 3 and 4",
                 "Study sessions — participants 5 and 6",
                 "Transcribe the session notes" ] },
      { id: :s2, role: :student, text: "Write up the HCI group project report",
        carried_from: [ 4, :s2 ],
        tasks: [ "HCI report — discussion section",
                 "HCI report — proofread the whole thing",
                 "HCI report — submit" ] },
      { id: :e1, role: :engineer, text: "Ship HAB-259: seat-based plan upgrades",
        tasks: [ "HAB-259 — plan matrix and pricing rules",
                 "HAB-259 — proration edge cases",
                 "HAB-259 — upgrade flow behind a flag" ] },
      { id: :e2, role: :engineer, text: "Cut Atlas dashboard first load under two seconds",
        tasks: [ "Profile the Atlas first paint",
                 "Code-split the chart bundle",
                 "Add skeleton states to the charts" ] }
    ],
    reflections: [
      "First two study sessions. Both ran long because the participants kept talking after the tasks were over, which is good data and bad scheduling.",
      "Participants three and four. Mapped out the plan matrix for HAB-259 — seat-based upgrades have far more edge cases than anyone admitted in planning.",
      "Last two participants. Six sessions in three days was too many and I could hear myself rushing the brief by the end of it.",
      nil,
      "Wrote the discussion section of the HCI report, finally. Profiled the Atlas first paint: 4.1 seconds, and almost all of it is the chart bundle.",
      "Code-split the chart bundle at home because it was bothering me. Down to 2.3 seconds. Should probably have rested instead."
    ]
  }
].freeze

# --- the account -------------------------------------------------------------------------------

user = User.find_or_initialize_by(email: EMAIL)
user.assign_attributes(username: USERNAME, password: PASSWORD, is_onboarded: true, eod_time: "21:30")

# Premium written straight onto the row, but only until a real Stripe subscription exists. Once one
# does, these columns belong to ApplyStripeSubscription and the webhook -- stamping them here would
# overwrite Stripe's period end with a made-up one, the drift the webhook exists to prevent.
if user.stripe_subscription_id.blank?
  user.assign_attributes(subscription_status: "active", subscription_period_end: 1.year.from_now)
end
user.save!

# --- teardown ----------------------------------------------------------------------------------

# Lifted out before the wipe and put back after it, so re-running costs no Gemini quota.
kept_summaries = WeeklySummary.joins(:weekly_plan)
                              .where(weekly_plans: { user_id: user.user_id })
                              .includes(:weekly_plan)
                              .to_h { |s| [ s.weekly_plan.start_date, s.slice(:content, :model, :generated_at) ] }

goal_ids = Goal.joins(:weekly_plan).where(weekly_plans: { user_id: user.user_id }).pluck(:goal_id)
# Goal deliberately declares no `dependent:` on its carryovers -- "carried for three weeks and then
# given up on" is exactly what the chain records -- so these have to go before the goals do.
GoalCarryover.where(source_goal_id: goal_ids).delete_all
GoalCarryover.where(destination_goal_id: goal_ids).delete_all

user.weekly_plans.destroy_all
user.roles.destroy_all
user.sharpen_the_saw_activities.destroy_all

# --- standing rows -----------------------------------------------------------------------------

roles = ROLES.transform_values { |attrs| user.roles.create!(attrs) }
activities = ACTIVITIES.transform_values { |attrs| user.sharpen_the_saw_activities.create!(attrs) }

# --- the weeks ---------------------------------------------------------------------------------

TODAY_INDEX = (Date.current - CURRENT_WEEK).to_i.clamp(0, 6)
STS_COMPLETION = 0.8
FIXED_ATTENDANCE = 0.92
LIVE_COMPLETION = 0.85

created_goals = {}
plans = []
task_count = 0

WEEKS.each_with_index do |week, w|
  week_start = WEEK_STARTS[w]
  plan = WeeklyPlan.for!(user, week_start)
  plans << plan

  week[:activities].each do |key|
    plan.weekly_plan_sts_activities.create!(sharpen_the_saw_activity: activities.fetch(key))
  end

  week[:goals].each do |spec|
    goal = roles.fetch(spec[:role]).goals.create!(
      weekly_plan_id: plan.weekly_plan_id,
      description: spec[:text],
      is_weekly_priority: spec.fetch(:priority, false),
      deleted_at: spec[:dropped] ? (week_start + 3).noon : nil
    )
    created_goals[[ w, spec[:id] ]] = goal
  end

  # Goal-backed work, queued in goal order and dealt out over the week's study and work blocks.
  study = week[:goals].select { |g| g[:role] == :student }
                      .flat_map { |g| g[:tasks].each_with_index.map { |name, i| [ g, name, i ] } }
  work = week[:goals].select { |g| g[:role] == :engineer }
                     .flat_map { |g| g[:tasks].each_with_index.map { |name, i| [ g, name, i ] } }

  rng = Random.new(20_260_101 + w)
  starred = []

  TEMPLATE.each do |slot|
    day = slot[:day]
    past = week[:live] ? day < TODAY_INDEX : true
    attrs = {
      user_id: user.user_id,
      weekly_plan_id: plan.weekly_plan_id,
      day_of_week: day,
      start_time: slot[:from],
      end_time: slot[:to]
    }

    case slot[:kind]
    when :fixed
      attrs.merge!(task_name: slot[:name], is_fixed_appointment: true,
                   is_completed: past && rng.rand < FIXED_ATTENDANCE)
    when :sts
      key = week[:picks].fetch(slot[:key], slot[:key])
      activity = activities.fetch(key)
      attrs.merge!(task_name: activity.activity_description,
                   sharpen_the_saw_activity_id: activity.sharpen_the_saw_activity_id,
                   is_completed: past && rng.rand < STS_COMPLETION)
    else
      spec, name, index = (slot[:kind] == :study ? study : work).shift
      raise "week #{w} ran out of #{slot[:kind]} tasks" if spec.nil?

      completed =
        if week[:live] then past && rng.rand < LIVE_COMPLETION
        elsif spec[:achieved] then true
        else index < spec[:tasks].size - spec.fetch(:missed, 1)
        end

      star = PRIORITY_DAYS[w].include?(day) && !starred.include?(day)
      starred << day if star

      attrs.merge!(task_name: name,
                   goal_id: created_goals.fetch([ w, spec[:id] ]).goal_id,
                   is_completed: completed,
                   is_daily_priority: star,
                   daily_priority_date: star ? week_start + day : nil)
    end

    Task.create!(attrs)
    task_count += 1
  end

  raise "week #{w} left #{study.size} study and #{work.size} work tasks unscheduled" if study.any? || work.any?

  # A night the user was asked. Tonight has no row yet -- the check-in has not happened.
  last_night = week[:live] ? TODAY_INDEX - 1 : 6
  (0..last_night).each do |day|
    plan.check_ins.create!(day_of_week: day,
                           status: day == week[:skipped_day] ? CheckIn::SKIPPED : CheckIn::COMPLETED)
  end

  week[:reflections].each_with_index do |content, day|
    next if content.nil? || day > last_night

    plan.evening_reflections.create!(day_of_week: day, content: content)
  end
end

# Continuity across weeks is an explicit link, never a reused goal, so these are written after every
# week exists rather than as each goal is created.
carryovers = 0
WEEKS.each_with_index do |week, w|
  week[:goals].each do |spec|
    next if spec[:carried_from].nil?

    GoalCarryover.create!(source_goal: created_goals.fetch(spec[:carried_from]),
                          destination_goal: created_goals.fetch([ w, spec[:id] ]))
    carryovers += 1
  end
end

# --- the AI weekly summaries -------------------------------------------------------------------

# Only the finished weeks. The live one has no Sunday reflection yet, and a summary needs all seven.
finished = plans.select { |plan| plan.start_date < CURRENT_WEEK }
generated = 0
restored = 0
failed = []

finished.each do |plan|
  if (kept = kept_summaries[plan.start_date])
    plan.create_weekly_summary!(kept)
    restored += 1
    next
  end

  reflections = plan.evening_reflections.order(:day_of_week).to_a
  next unless reflections.size == GeminiSummaryClient::DAY_NAMES.size

  # The key is on the free tier at five requests a minute, and there are five weeks to write.
  sleep 15 if generated.positive?

  result = GeminiSummaryClient.summarise(reflections)
  if result.ok?
    plan.create_weekly_summary!(content: result.content, model: GeminiSummaryClient::MODEL,
                                generated_at: Time.current)
    generated += 1
    puts "  summarised #{plan.start_date}"
  else
    failed << [ plan.start_date, result.error ]
    puts "  could not summarise #{plan.start_date} (#{result.error})"
  end
end

# --- what was built ----------------------------------------------------------------------------

puts
puts "Seeded #{EMAIL} / #{PASSWORD}"
puts "  premium until   #{user.subscription_period_end.to_date} (#{user.subscription_status})"
puts "  roles           #{roles.values.map(&:role_name).join(', ')}"
puts "  renewal library #{activities.size} activities across four dimensions"
puts "  weeks           #{plans.size} (#{WEEK_STARTS.first} .. #{WEEK_STARTS.last}), #{finished.size} finished"
puts "  goals           #{created_goals.size}, #{carryovers} carried forward"
puts "  tasks           #{task_count}, of which #{Task.where(user_id: user.user_id, is_fixed_appointment: true).count} fixed appointments"
puts "  reflections     #{EveningReflection.joins(:weekly_plan).where(weekly_plans: { user_id: user.user_id }).count}"
puts "  summaries       #{generated} generated, #{restored} kept from a previous run"
if failed.any?
  puts
  puts "  Gemini did not answer for: #{failed.map(&:first).join(', ')}"
  puts "  Re-run this script to fill them in; the weeks that did work are kept as they are."
end
puts
if user.stripe_subscription_id.blank?
  puts "  No Stripe subscription: payments rows come from the webhook and nothing else, so this"
  puts "  account is premium with no invoices behind it."
else
  puts "  Stripe subscription #{user.stripe_subscription_id} left as the webhook wrote it."
end
