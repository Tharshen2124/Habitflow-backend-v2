class UsersController < ApplicationController
  include Authenticatable

  def complete_onboarding
    current_user.update!(is_onboarded: true)
    render json: { user: { is_onboarded: current_user.is_onboarded } }, status: :ok
  end
end
