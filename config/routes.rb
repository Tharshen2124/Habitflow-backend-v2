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
  # Defines the root path route ("/")
  # root "posts#index"
end
