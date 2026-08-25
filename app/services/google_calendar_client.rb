require "net/http"

# Google Calendar API v3, only the six calls this app makes. Follows GeminiSummaryClient: a plain
# class over stdlib Net::HTTP, because there is no HTTP client gem in the Gemfile and two Google
# services do not between them earn one.
#
# Every method takes an access token rather than a user. Resolving a live token -- refreshing it,
# and noticing when the grant has been revoked -- is CalendarAccess's job, and keeping the two apart
# means this class can be tested with a string.
class GoogleCalendarClient
  API_HOST = "https://www.googleapis.com/calendar/v3".freeze
  TIMEOUT_SECONDS = 15

  # Retried because they mean "try again", not "you asked for the wrong thing". 429 is included --
  # unlike in GeminiSummaryClient, where it means a free-tier minute has been used up and the user
  # is told to wait. Here it is a burst of thirty writes briefly outrunning a per-minute quota that
  # is otherwise enormous, and a second of backoff clears it without the user ever knowing.
  RETRY_CODES = [ 429, 500, 502, 503, 504 ].freeze
  MAX_ATTEMPTS = 3
  RETRY_BACKOFF_SECONDS = 1

  # A parsed body, or the reason there isn't one. `error` is nil on success and otherwise one of
  # :unauthorized (the grant is gone -- the user must reconnect), :rate_limited or :unavailable.
  Result = Data.define(:body, :error) do
    def ok? = error.nil?
  end

  # The seam the tests replace, kept as its own type so standing in for Google needs no HTTP
  # objects. Same arrangement as GeminiSummaryClient::Response.
  Response = Data.define(:code, :body)

  def self.create_calendar(token, summary:, description:, time_zone:)
    call(:post, "/calendars", token,
         body: { summary: summary, description: description, timeZone: time_zone })
  end

  def self.delete_calendar(token, calendar_id)
    call(:delete, "/calendars/#{escape(calendar_id)}", token, missing_is_success: true)
  end

  # Every HabitFlow event in a date range, following pageToken to the end. `singleEvents` expands
  # nothing here -- this app writes no recurring events -- but it keeps the response shape stable if
  # a user ever drags a recurring event of their own into the calendar by hand.
  def self.list_events(token, calendar_id, time_min:, time_max:, properties:)
    events = []
    page_token = nil

    loop do
      # An array of pairs rather than a hash, because Google ANDs *repeated*
      # `privateExtendedProperty` params and Rails' to_query would render an array as
      # `privateExtendedProperty[]=`, which it ignores -- silently widening the search to the whole
      # calendar instead of narrowing it to one week.
      query = properties.map { |p| [ "privateExtendedProperty", p ] } + [
        [ "timeMin", time_min ],
        [ "timeMax", time_max ],
        [ "singleEvents", "true" ],
        [ "showDeleted", "false" ],
        [ "maxResults", "250" ]
      ]
      query << [ "pageToken", page_token ] if page_token.present?

      result = call(:get, "/calendars/#{escape(calendar_id)}/events", token, query: query)
      return result unless result.ok?

      events.concat(result.body["items"] || [])
      page_token = result.body["nextPageToken"]
      break if page_token.blank?
    end

    Result.new(body: events, error: nil)
  end

  def self.insert_event(token, calendar_id, event)
    call(:post, "/calendars/#{escape(calendar_id)}/events", token, body: event)
  end

  def self.patch_event(token, calendar_id, event_id, event)
    call(:patch, "/calendars/#{escape(calendar_id)}/events/#{escape(event_id)}", token, body: event)
  end

  # An event someone already deleted by hand is in the state we wanted, so 404/410 is success. Left
  # as a failure it would make every subsequent sync report an error it could do nothing about.
  def self.delete_event(token, calendar_id, event_id)
    call(:delete, "/calendars/#{escape(calendar_id)}/events/#{escape(event_id)}", token,
         missing_is_success: true)
  end

  # The seam. Public, and returns a plain Response.
  def self.request(method, path, token, body: nil, query: {})
    uri = URI("#{API_HOST}#{path}")
    # An Array is a list of [key, value] pairs, which is the only way to repeat a key.
    uri.query = query.is_a?(Array) ? URI.encode_www_form(query) : query.to_query if query.present?

    request = REQUEST_CLASSES.fetch(method).new(uri)
    request["Authorization"] = "Bearer #{token}"
    if body
      request["Content-Type"] = "application/json"
      request.body = body.to_json
    end

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                               open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS) do |http|
      http.request(request)
    end

    Response.new(code: response.code.to_i, body: response.body)
  end

  REQUEST_CLASSES = {
    get: Net::HTTP::Get,
    post: Net::HTTP::Post,
    patch: Net::HTTP::Patch,
    delete: Net::HTTP::Delete
  }.freeze

  def self.call(method, path, token, body: nil, query: {}, missing_is_success: false)
    response = with_retries(method, path, token, body: body, query: query)

    return Result.new(body: {}, error: nil) if missing_is_success && [ 404, 410 ].include?(response.code)
    return Result.new(body: {}, error: nil) if response.code == 204

    if response.code == 401 || (response.code == 403 && !rate_limited?(response))
      # The user revoked the grant, or it never carried the calendar scope. Retrying is pointless;
      # the only fix is reconnecting, which is what the caller turns this into.
      Rails.logger.error("Google Calendar refused the grant (#{response.code}): #{response.body.to_s.truncate(300)}")
      return Result.new(body: nil, error: :unauthorized)
    end

    return Result.new(body: nil, error: :rate_limited) if response.code == 429 || rate_limited?(response)

    # Its own error rather than a generic failure: "the thing you named is gone" has a sensible
    # response at every call site here (re-insert the event, recreate the calendar) and "Google is
    # broken" has none of them.
    return Result.new(body: nil, error: :not_found) if [ 404, 410 ].include?(response.code)

    unless response.code.between?(200, 299)
      Rails.logger.error("Google Calendar responded #{response.code}: #{response.body.to_s.truncate(300)}")
      return Result.new(body: nil, error: :unavailable)
    end

    Result.new(body: response.body.present? ? JSON.parse(response.body) : {}, error: nil)
  rescue KeyError => e
    Rails.logger.error("GoogleCalendarClient is not configured: #{e.message}")
    Result.new(body: nil, error: :unavailable)
  rescue StandardError => e
    # A timeout, a socket error, or a body that is not the JSON we expect.
    Rails.logger.error("Google Calendar request failed: #{e.class}: #{e.message}")
    Result.new(body: nil, error: :unavailable)
  end

  def self.with_retries(method, path, token, body:, query:)
    attempt = 0
    loop do
      attempt += 1
      response = request(method, path, token, body: body, query: query)
      retryable = RETRY_CODES.include?(response.code) || rate_limited?(response)
      return response unless retryable && attempt < MAX_ATTEMPTS

      Rails.logger.warn("Google Calendar responded #{response.code}, retrying (attempt #{attempt} of #{MAX_ATTEMPTS})")
      sleep(RETRY_BACKOFF_SECONDS * attempt)
    end
  end

  # Calendar reports a tripped quota as a 403 carrying a reason, not only as a 429, and a 403 that
  # is *not* one of those means the grant itself is bad -- two opposite responses behind one code.
  def self.rate_limited?(response)
    return false unless response.code == 403

    reason = JSON.parse(response.body.to_s).dig("error", "errors", 0, "reason")
    [ "rateLimitExceeded", "userRateLimitExceeded" ].include?(reason)
  rescue StandardError
    false
  end

  def self.escape(value) = ERB::Util.url_encode(value.to_s)

  private_class_method :call, :with_retries, :escape
end
