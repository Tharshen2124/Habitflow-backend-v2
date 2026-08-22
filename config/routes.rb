Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  post "signup" => "authentication#signup"
  post "login" => "authentication#login"
  get "login" => "authentication#login"
  get "callback" => "authentication#callback"
  patch "users/complete_onboarding" => "users#complete_onboarding"
  post "onboarding/roles" => "roles#create"
  get "onboarding/roles" => "roles#index"
  post "onboarding/sharpen-the-saw" => "sharpen_the_saw_activity#create"
  get "onboarding/sharpen-the-saw" => "sharpen_the_saw_activity#index"
  get "sharpen-the-saw-activities" => "sharpen_the_saw_activity#index"
  post "sharpen-the-saw-activities" => "sharpen_the_saw_activity#create_activity"
  patch "sharpen-the-saw-activities/:id" => "sharpen_the_saw_activity#update_activity"
  delete "sharpen-the-saw-activities/:id" => "sharpen_the_saw_activity#destroy_activity"
  post "onboarding/fixed-appointments" => "task#create_fixed_appointments"
  get "onboarding/fixed-appointments" => "task#index_fixed_appointments"
  post "onboarding/schedule-tasks" => "task#create_scheduled_tasks"
  get "onboarding/schedule-tasks" => "task#index_scheduled_tasks"
  # Standing roles & goals management. Goals belong to exactly one week, so every one of these is
  # week-scoped; roles themselves are long-lived and are archived rather than deleted.
  get "roles" => "roles#index"
  post "roles" => "roles#create_role"
  patch "roles/:id" => "roles#update_role"
  delete "roles/:id" => "roles#destroy_role"
  get "roles/:id/archive-preview" => "roles#archive_preview"
  post "roles/:id/restore" => "roles#restore_role"
  # The two literal paths are declared before "goals/:id" so they are not swallowed by it.
  get "goals/carry-forward-candidates" => "goals#carry_forward_candidates"
  post "goals/carry-forward" => "goals#carry_forward"
  post "goals" => "goals#create"
  patch "goals/:id" => "goals#update"
  delete "goals/:id" => "goals#destroy"
  post "goals/:id/restore" => "goals#restore"
  # The repeatable planning flow. It shares the task controller with onboarding -- the actions are
  # identical -- but onboarding is walked once and never returned to, so a flow the user runs every
  # week should not be posting to /onboarding paths.
  get  "weekly-plans/sharpen-the-saw" => "weekly_plans#sharpen_the_saw"
  put  "weekly-plans/sharpen-the-saw" => "weekly_plans#update_sharpen_the_saw"
  get  "weekly-plans/fixed-appointments" => "task#index_fixed_appointments"
  post "weekly-plans/fixed-appointments" => "task#create_fixed_appointments"
  get  "weekly-plans/tasks" => "task#index_scheduled_tasks"
  post "weekly-plans/tasks" => "task#create_scheduled_tasks"
  get "weekly-plans" => "weekly_plans#show"
  # Ticking one task off. Not week-scoped -- the row names its own week -- and deliberately apart
  # from the bulk creates above, which reconcile a whole week's plan.
  patch "tasks/:id/completion" => "task#update_completion"
  # Evening reflections and the weekly AI summary. Reads and writes alike resolve the week without
  # creating it -- a reflection belongs to a plan, so a week you never planned has nowhere to put
  # one. The week strip is a range rather than a single week, and returns counts, never text.
  get "weekly-plans/evening-reflections" => "evening_reflections#index"
  put "weekly-plans/evening-reflections" => "evening_reflections#upsert"
  get "evening-reflections/weeks" => "evening_reflections#weeks"
  post "weekly-plans/weekly-summary" => "weekly_summaries#create"
  # Past weeks, read as they were recorded rather than as they would be planned today: these are the
  # only reads that do not filter archived roles, dropped goals and deleted activities out. The
  # literal segment is declared first so "history/weeks" is not swallowed by "history".
  get "history/weeks" => "history#weeks"
  get "history" => "history#show"
  # The analytics figures: counts per planned week across a range, never content. Reads past weeks
  # as recorded, the same way /history does, and for the same reason -- it resolves a week through
  # `task -> goal -> role`, so archived roles and dropped goals still have to resolve.
  get "analytics" => "analytics#show"
  # Defines the root path route ("/")
  # root "posts#index"
end
