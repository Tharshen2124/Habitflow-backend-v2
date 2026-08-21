require "test_helper"

class GeminiSummaryClientTest < ActiveSupport::TestCase
  def reflections
    [
      EveningReflection.new(day_of_week: 2, content: "Blocked out the morning."),
      EveningReflection.new(day_of_week: 0, content: "Slow start."),
      EveningReflection.new(day_of_week: 6, content: "Planned next week.")
    ]
  end

  def ok_body(text)
    { candidates: [ { content: { parts: [ { text: text } ] } } ] }.to_json
  end

  def responding(code, body)
    GeminiSummaryClient::Response.new(code: code, body: body)
  end

  # Monday first regardless of the order they arrive in, so "from Wednesday onwards" in the
  # summary means what it says.
  test "lays the week out in day order, labelled by day name" do
    journal = GeminiSummaryClient.journal(reflections)

    assert_equal [ "Monday: Slow start.", "Wednesday: Blocked out the morning.", "Sunday: Planned next week." ],
                 journal.split("\n\n")
  end

  test "returns the model's text on success" do
    stubbing(GeminiSummaryClient, :post, responding(200, ok_body("  A steady week.  "))) do
      result = GeminiSummaryClient.summarise(reflections)

      assert_predicate result, :ok?
      assert_equal "A steady week.", result.content
    end
  end

  # The free tier allows five requests a minute. Being throttled needs a longer wait than a request
  # can hold, so it is reported to the user rather than retried -- and it must not read to them as
  # the feature being broken.
  test "reports being throttled separately from being broken, and does not retry it" do
    calls = 0

    stubbing(GeminiSummaryClient, :post, ->(*) { calls += 1; responding(429, "{}") }) do
      assert_equal :rate_limited, GeminiSummaryClient.summarise(reflections).error
    end

    assert_equal 1, calls, "a throttled request should not be retried"
  end

  test "a refused request is not retried either" do
    calls = 0

    stubbing(GeminiSummaryClient, :post, ->(*) { calls += 1; responding(400, "{}") }) do
      assert_equal :unavailable, GeminiSummaryClient.summarise(reflections).error
    end

    assert_equal 1, calls
  end

  # Gemini answers 503 "experiencing high demand" often enough to hit it in a single test run, and
  # a summary can only ever be generated once -- so a blip must not cost the user their one go.
  test "retries a transient upstream failure, then gives up" do
    calls = 0

    stubbing(GeminiSummaryClient, :sleep, nil) do
      stubbing(GeminiSummaryClient, :post, ->(*) { calls += 1; responding(503, "{}") }) do
        assert_equal :unavailable, GeminiSummaryClient.summarise(reflections).error
      end
    end

    assert_equal GeminiSummaryClient::MAX_ATTEMPTS, calls
  end

  test "a retry that succeeds returns the summary" do
    calls = 0
    answer = ->(*) { calls += 1; calls == 1 ? responding(503, "{}") : responding(200, ok_body("A steady week.")) }

    stubbing(GeminiSummaryClient, :sleep, nil) do
      stubbing(GeminiSummaryClient, :post, answer) do
        assert_equal "A steady week.", GeminiSummaryClient.summarise(reflections).content
      end
    end

    assert_equal 2, calls
  end

  # A safety block or an exhausted token budget answers 200 with no text part. Storing that would
  # leave the user with an empty summary they can never regenerate.
  test "treats a success carrying no text as a failure" do
    [ ok_body(""), { candidates: [] }.to_json, { candidates: [ { content: {} } ] }.to_json ].each do |body|
      stubbing(GeminiSummaryClient, :post, responding(200, body)) do
        result = GeminiSummaryClient.summarise(reflections)

        assert_not result.ok?, "#{body} should not count as a summary"
        assert_nil result.content
      end
    end
  end

  test "a body that is not the JSON we expect is a failure, not an exception" do
    stubbing(GeminiSummaryClient, :post, responding(200, "<html>502 Bad Gateway</html>")) do
      assert_equal :unavailable, GeminiSummaryClient.summarise(reflections).error
    end
  end

  test "a network failure is a failure, not an exception" do
    stubbing(GeminiSummaryClient, :post, ->(*) { raise Net::ReadTimeout }) do
      assert_equal :unavailable, GeminiSummaryClient.summarise(reflections).error
    end
  end
end
