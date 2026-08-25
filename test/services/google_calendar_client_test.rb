require "test_helper"

class GoogleCalendarClientTest < ActiveSupport::TestCase
  def response(code, body = "{}")
    GoogleCalendarClient::Response.new(code: code, body: body)
  end

  def rate_limit_body
    { error: { errors: [ { reason: "rateLimitExceeded" } ] } }.to_json
  end

  # The retries sleep, and three tests do not need to take six seconds to prove a loop runs.
  def with_client(responses)
    queue = Array(responses)
    stubbing(GoogleCalendarClient, :sleep, nil) do
      stubbing(GoogleCalendarClient, :request, ->(*) { queue.size > 1 ? queue.shift : queue.first }) do
        yield
      end
    end
  end

  def insert(responses)
    with_client(responses) { GoogleCalendarClient.insert_event("token", "cal", { summary: "x" }) }
  end

  test "a 2xx comes back parsed" do
    result = insert(response(200, { "id" => "evt-1" }.to_json))

    assert result.ok?
    assert_equal "evt-1", result.body["id"]
  end

  test "a 401 is the grant, not an outage" do
    assert_equal :unauthorized, insert(response(401)).error
  end

  # 403 means two opposite things: a tripped quota, which clears in a second, and a missing scope,
  # which never clears without the user reconnecting.
  test "a 403 is read by its reason" do
    assert_equal :rate_limited, insert(response(403, rate_limit_body)).error
    assert_equal :unauthorized, insert(response(403, { error: { errors: [ { reason: "insufficientPermissions" } ] } }.to_json)).error
  end

  test "a 429 is a rate limit" do
    assert_equal :rate_limited, insert(response(429)).error
  end

  test "a missing event is its own answer, not a generic failure" do
    assert_equal :not_found, insert(response(404)).error
  end

  test "anything else is unavailable" do
    assert_equal :unavailable, insert(response(500)).error
  end

  test "a transient failure is retried and can succeed" do
    result = insert([ response(503), response(200, { "id" => "evt-2" }.to_json) ])

    assert result.ok?
    assert_equal "evt-2", result.body["id"]
  end

  test "retries stop at MAX_ATTEMPTS" do
    attempts = 0
    stubbing(GoogleCalendarClient, :sleep, nil) do
      stubbing(GoogleCalendarClient, :request, ->(*) { attempts += 1; response(503) }) do
        assert_equal :unavailable, GoogleCalendarClient.insert_event("token", "cal", {}).error
      end
    end

    assert_equal GoogleCalendarClient::MAX_ATTEMPTS, attempts
  end

  test "a deleted event counts as deleted" do
    with_client(response(410)) do
      assert GoogleCalendarClient.delete_event("token", "cal", "gone").ok?
    end
    with_client(response(204, "")) do
      assert GoogleCalendarClient.delete_event("token", "cal", "there").ok?
    end
  end

  test "a body that is not JSON is unavailable rather than an exception" do
    assert_equal :unavailable, insert(response(200, "<html>gateway</html>")).error
  end

  test "list_events follows nextPageToken and concatenates" do
    pages = [
      response(200, { "items" => [ { "id" => "a" } ], "nextPageToken" => "p2" }.to_json),
      response(200, { "items" => [ { "id" => "b" } ] }.to_json)
    ]

    result = with_client(pages) do
      GoogleCalendarClient.list_events("token", "cal", time_min: "x", time_max: "y", properties: [ "habitflow=1" ])
    end

    assert result.ok?
    assert_equal %w[a b], result.body.map { |e| e["id"] }
  end

  # Rails' to_query would render these as `privateExtendedProperty[]=`, which Google ignores --
  # silently widening the search to the whole calendar instead of narrowing it to one week.
  test "repeated extended-property filters survive as repeated keys" do
    seen = nil
    stubbing(GoogleCalendarClient, :request, ->(_m, _p, _t, **kwargs) {
      seen = kwargs[:query]
      response(200, { "items" => [] }.to_json)
    }) do
      GoogleCalendarClient.list_events("token", "cal", time_min: "x", time_max: "y",
                                       properties: [ "habitflow=1", "habitflow_week=2026-08-17" ])
    end

    query = URI.encode_www_form(seen)
    assert_includes query, "privateExtendedProperty=habitflow%3D1"
    assert_includes query, "privateExtendedProperty=habitflow_week%3D2026-08-17"
    assert_not_includes query, "%5B%5D"
  end
end
