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
  # Defines the root path route ("/")
  # root "posts#index"
end
