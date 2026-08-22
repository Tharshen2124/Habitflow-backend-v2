class UsersController < ApplicationController
  include Authenticatable

  def complete_onboarding
    current_user.update!(is_onboarded: true)
    render json: { user: { is_onboarded: current_user.is_onboarded } }, status: :ok
  end

  # When the End-of-Day check-in appears. /settings reads and writes it here; the dashboard gets it
  # on the weekly-plan response instead, so deciding whether to prompt costs it no extra request.
  def eod_time
    render json: { eod_time: current_user.eod_time.strftime("%H:%M") }
  end

  # Sent as "HH:MM" and stored as a bare `time`. It is a wall-clock time with no zone attached, for
  # the same reason week_start is client-supplied everywhere else: the server holds no timezone for
  # the user, so 21:00 means 21:00 on whichever clock they are reading.
  def update_eod_time
    current_user.update!(eod_time: params[:eod_time])
    render json: { eod_time: current_user.eod_time.strftime("%H:%M") }
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end
end
