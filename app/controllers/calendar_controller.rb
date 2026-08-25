class CalendarController < ApplicationController
  include Authenticatable
  include WeekScoped
  include CalendarSyncable

  # The one action Google itself calls. It arrives as a browser redirect, which cannot carry an
  # Authorization header -- the state JWT is what says who came back.
  skip_before_action :authenticate_request!, only: [ :callback ]

  STATE_PURPOSE = "google_calendar_state".freeze

  # A runaway guard rather than a policy. /weekly-plan only ever plans this week and the next, so
  # this is two in practice; the cap exists so that a user who has somehow filed fifty future plans
  # cannot turn one Save into fifty round trips to Google.
  MAX_WEEKS = 8

  def show
    render json: { calendar: calendar_json }
  end

  # Returns the consent URL rather than redirecting to it. A redirect would have to be followed by
  # the browser, and the browser cannot send the bearer token that says which account is being
  # connected -- so the frontend asks for the URL with its token, then navigates.
  def connect
    zone = current_time_zone
    return render json: { errors: [ "A valid IANA time zone is required" ] }, status: :unprocessable_entity if zone.nil?

    state = JsonWebToken.encode(
      { purpose: STATE_PURPOSE, user_id: current_user.user_id, time_zone: zone },
      exp: 5.minutes.from_now
    )
    render json: { url: GoogleOauthClient.calendar_authorization_url(state) }
  end

  def callback
    return redirect_with("calendar_error=access_denied") if params[:error].present?

    state = params[:state] && JsonWebToken.decode(params[:state])
    return redirect_with("calendar_error=invalid_state") unless state && state[:purpose] == STATE_PURPOSE

    user = User.find_by(user_id: state[:user_id])
    return redirect_with("calendar_error=invalid_state") unless user

    tokens = GoogleOauthClient.exchange_calendar_code(params[:code])
    return redirect_with("calendar_error=token_exchange_failed") unless tokens

    # Google lets a user untick individual scopes on the consent screen. Without this the account
    # would be stored as connected and every sync would fail on a token that never had the right.
    unless tokens["scope"].to_s.include?(GoogleOauthClient::CALENDAR_SCOPE)
      return redirect_with("calendar_error=calendar_scope_declined")
    end

    # A refresh token is what makes this last beyond the hour the access token is good for. Google
    # only reissues one when asked (`prompt: consent`), so its absence is a real failure here rather
    # than something to paper over with the old value.
    return redirect_with("calendar_error=no_refresh_token") if tokens["refresh_token"].blank?

    store_grant(user, tokens)
    calendar_id = CalendarAccess.ensure_calendar(user, tokens["access_token"], state[:time_zone])
    return redirect_with("calendar_error=calendar_create_failed") if calendar_id.nil?

    redirect_with("calendar=connected")
  end

  def update_settings
    current_user.update!(
      calendar_sync_enabled: ActiveModel::Type::Boolean.new.cast(params[:sync_enabled]) != false,
      export_preference: CalendarExportPreference.sanitise(export_preference_params)
    )
    # Unticking a category has to take its events off the calendar, not merely stop adding them --
    # which is a whole-week reconcile, so it goes through the ordinary auto-sync path.
    sync_calendar_later
    render json: { calendar: calendar_json }
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  # The Sync button. Inline rather than enqueued: the user pressed it and is watching, so the point
  # is to be able to tell them what happened.
  def sync
    return render json: { errors: [ "Google Calendar is not connected" ] }, status: :unprocessable_entity unless current_user.calendar_connected?
    return render_invalid_week_start if week_start.nil?

    zone = current_time_zone
    return render json: { errors: [ "A valid IANA time zone is required" ] }, status: :unprocessable_entity if zone.nil?

    results = weeks_from(week_start).map do |start_date|
      SyncWeekToCalendar.call(user: current_user, week_start: start_date, time_zone: zone)
    end

    failed = results.reject(&:ok?).first
    return render_upstream_error(failed.error) if failed

    current_user.update!(calendar_synced_at: Time.current)
    render json: {
      weeks: results.size,
      written: results.sum(&:written),
      deleted: results.sum(&:deleted),
      calendar: calendar_json
    }
  end

  def disconnect
    if (token = CalendarAccess.token_for(current_user))
      # Deleting the calendar takes every event with it, which is what "remove them" means when the
      # events live somewhere we created. Best-effort: the row is cleared either way, because
      # leaving a user connected to a calendar they asked to leave is the worse failure.
      GoogleCalendarClient.delete_calendar(token, current_user.calendar_id)
      GoogleOauthClient.revoke(token)
    end

    current_user.disconnect_calendar!
    render json: { calendar: calendar_json }
  end

  private

  def store_grant(user, tokens)
    user.update!(
      calendar_access_token: tokens["access_token"],
      calendar_refresh_token: tokens["refresh_token"],
      calendar_token_expires_at: Time.current + tokens["expires_in"].to_i.seconds
    )
  end

  # The current week and every future week that has a plan; never a past one. A finished week is
  # read as it was recorded everywhere else in this app, and rewriting one on Google would be the
  # one place that stopped being true.
  def weeks_from(from)
    current_user.weekly_plans.where(start_date: from..).order(:start_date).limit(MAX_WEEKS).pluck(:start_date)
  end

  def render_upstream_error(error)
    case error
    when :disconnected
      render json: { errors: [ "Google Calendar is no longer connected. Reconnect to sync." ] },
             status: :unprocessable_entity
    when :unauthorized
      render json: { errors: [ "Google refused the connection. Reconnect to sync." ] },
             status: :unprocessable_entity
    when :rate_limited
      render json: { errors: [ "Google is rate-limiting this account. Try again in a minute." ] },
             status: :too_many_requests
    else
      render json: { errors: [ "Google Calendar is unreachable right now. Try again shortly." ] },
             status: :bad_gateway
    end
  end

  def export_preference_params
    params.fetch(:export_preference, {})
          .permit(:fixed_appointments, excluded_dimensions: [], excluded_role_ids: [])
          .to_h
  end

  def redirect_with(fragment)
    redirect_to "#{ENV.fetch('FRONTEND_ORIGIN')}/settings##{fragment}", allow_other_host: true
  end

  def calendar_json
    {
      connected: current_user.calendar_connected?,
      sync_enabled: current_user.calendar_sync_enabled,
      export_preference: CalendarExportPreference.new(current_user.export_preference).to_h,
      synced_at: current_user.calendar_synced_at&.iso8601
    }
  end
end
