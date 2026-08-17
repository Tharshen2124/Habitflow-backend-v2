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
  post "onboarding/sharpen-the-saw" => "sharpen_the_saw_activity#create"
  # Defines the root path route ("/")
  # root "posts#index"
end
