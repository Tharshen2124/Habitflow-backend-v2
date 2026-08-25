require "net/http"

class GoogleOauthClient
  AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
  TOKEN_URL = "https://oauth2.googleapis.com/token"
  REVOKE_URL = "https://oauth2.googleapis.com/revoke"
  USERINFO_URL = "https://www.googleapis.com/oauth2/v3/userinfo"

  # Read/write on the user's own calendars. The narrower calendar.events is not enough: connecting
  # creates a secondary "HabitFlow" calendar, and calendars.insert is not covered by it.
  CALENDAR_SCOPE = "https://www.googleapis.com/auth/calendar"

  def self.authorization_url(state)
    params = {
      client_id: ENV.fetch("GOOGLE_OAUTH_CLIENT_ID"),
      redirect_uri: ENV.fetch("GOOGLE_OAUTH_REDIRECT_URI"),
      response_type: "code",
      scope: "openid email profile",
      access_type: "offline",
      prompt: "consent",
      state: state
    }
    "#{AUTH_URL}?#{params.to_query}"
  end

  # The second consent screen, reached from /settings rather than from sign-in. It is deliberately
  # separate: a user who signs up with a password never touches the sign-in flow, and asking every
  # user for calendar access merely to log in would be a worse trade than asking the few who want it.
  def self.calendar_authorization_url(state)
    params = {
      client_id: ENV.fetch("GOOGLE_OAUTH_CLIENT_ID"),
      redirect_uri: ENV.fetch("GOOGLE_CALENDAR_REDIRECT_URI"),
      response_type: "code",
      scope: CALENDAR_SCOPE,
      access_type: "offline",
      # Forces a fresh consent screen, which is what guarantees a refresh token comes back -- Google
      # issues one only when it asks, so a user reconnecting after a revoke would otherwise get an
      # access token good for an hour and nothing to renew it with.
      prompt: "consent",
      # Incremental authorisation: the new token carries the scopes this account has already
      # granted as well as the calendar one, so connecting a calendar does not quietly drop the
      # sign-in grant.
      include_granted_scopes: "true",
      state: state
    }
    "#{AUTH_URL}?#{params.to_query}"
  end

  def self.exchange_code_for_tokens(code)
    exchange(code, ENV.fetch("GOOGLE_OAUTH_REDIRECT_URI"))
  end

  # Google matches the redirect_uri against the one the consent request carried, so the calendar
  # flow cannot reuse the sign-in exchange above.
  def self.exchange_calendar_code(code)
    exchange(code, ENV.fetch("GOOGLE_CALENDAR_REDIRECT_URI"))
  end

  # Trades a refresh token for a fresh access token. Access tokens last an hour and a week's plan
  # can be synced weeks after it was connected, so without this the feature works for one hour and
  # then stops. Returns nil for any failure except a revoked grant, which the caller has to treat
  # differently -- see CalendarAccess.
  def self.refresh_access_token(refresh_token)
    response = Net::HTTP.post_form(URI(TOKEN_URL), {
      refresh_token: refresh_token,
      client_id: ENV.fetch("GOOGLE_OAUTH_CLIENT_ID"),
      client_secret: ENV.fetch("GOOGLE_OAUTH_CLIENT_SECRET"),
      grant_type: "refresh_token"
    })
    return JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)

    # invalid_grant means the user revoked access from their Google account settings, or the token
    # was already used to the point of expiry. Retrying will never work, so it is reported as its
    # own thing rather than as a transient failure.
    { "error" => JSON.parse(response.body)["error"] }
  rescue StandardError
    nil
  end

  # Best-effort: a disconnect should not fail because Google was slow to hear about it. The row is
  # cleared either way, which is what the user actually asked for.
  def self.revoke(token)
    Net::HTTP.post_form(URI(REVOKE_URL), { token: token })
    true
  rescue StandardError
    false
  end

  def self.fetch_profile(access_token)
    uri = URI(USERINFO_URL)
    req = Net::HTTP::Get.new(uri).tap { |r| r["Authorization"] = "Bearer #{access_token}" }
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
    response.is_a?(Net::HTTPSuccess) ? JSON.parse(response.body) : nil
  end

  def self.exchange(code, redirect_uri)
    response = Net::HTTP.post_form(URI(TOKEN_URL), {
      code: code,
      client_id: ENV.fetch("GOOGLE_OAUTH_CLIENT_ID"),
      client_secret: ENV.fetch("GOOGLE_OAUTH_CLIENT_SECRET"),
      redirect_uri: redirect_uri,
      grant_type: "authorization_code"
    })
    response.is_a?(Net::HTTPSuccess) ? JSON.parse(response.body) : nil
  end

  private_class_method :exchange
end
