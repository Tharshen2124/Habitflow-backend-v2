require "test_helper"

class SubscriptionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @subscriber = users(:subscriber)
  end

  def auth(user = @user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user.to_token_payload)}" }
  end

  def body = JSON.parse(response.body)

  def ok(value) = StripeClient::Result.new(value: value, error: nil)
  def failed(error) = StripeClient::Result.new(value: nil, error: error)

  # Stripe's objects answer to dot notation all the way down, and a stand-in needs to do the same
  # and nothing more. Building them from plain hashes keeps each test's fixture readable as the JSON
  # Stripe actually sends.
  def stripe_object(value)
    case value
    when Hash
      Struct.new(*value.keys, keyword_init: true).new(**value.transform_values { |v| stripe_object(v) })
    when Array
      value.map { |v| stripe_object(v) }
    else
      value
    end
  end

  def subscription_object(id: "sub_123", status: "active", period_end: 30.days.from_now.to_i, customer: "cus_123")
    stripe_object(
      id: id, status: status, customer: customer,
      items: { data: [ { current_period_end: period_end } ] }
    )
  end

  def invoice_object(id: "in_123", customer: "cus_fixture_subscriber", amount_paid: 2500, amount_due: 2500,
                     currency: "myr", paid_at: Time.current.to_i)
    stripe_object(
      id: id, customer: customer, amount_paid: amount_paid, amount_due: amount_due,
      currency: currency, status_transitions: { paid_at: paid_at }
    )
  end

  def event_object(type, object)
    stripe_object(type: type, data: { object: object })
  end

  # Standing in for Stripe with something that fails the test if it is reached.
  def refusing_to_call
    ->(*) { flunk "Stripe was called before the preconditions were checked" }
  end

  def send_webhook(event)
    stubbing(StripeClient, :construct_event, ok(event)) do
      post "/subscription/webhook", params: { anything: true }, as: :json
    end
  end

  # ── authentication ───────────────────────────────────────────────────────────

  test "every endpoint but the webhook is unauthorized without a token" do
    get "/subscription"
    assert_response :unauthorized

    post "/subscription/checkout", as: :json
    assert_response :unauthorized

    post "/subscription/portal", as: :json
    assert_response :unauthorized

    post "/subscription/confirm", params: { session_id: "cs_1" }, as: :json
    assert_response :unauthorized
  end

  # The one action Stripe itself calls. It has no token to send, so it must not be refused for
  # lacking one -- the signature is what stands in.
  test "the webhook is reachable without a token" do
    stubbing(StripeClient, :construct_event, failed(:invalid_signature)) do
      post "/subscription/webhook", params: {}, as: :json
    end
    assert_response :bad_request
  end

  # ── show ─────────────────────────────────────────────────────────────────────

  test "reports a free account as not premium" do
    stubbing(StripeClient, :fetch_plan, ok({ amount_cents: 2500, currency: "myr", interval: "month" })) do
      get "/subscription", headers: auth
    end

    assert_response :success
    assert_equal false, body["subscription"]["premium"]
    assert_equal false, body["subscription"]["manageable"]
    assert_equal 2500, body["plan"]["amount_cents"]
    assert_equal "myr", body["plan"]["currency"]
  end

  test "reports a subscribed account as premium and manageable" do
    stubbing(StripeClient, :fetch_plan, ok({ amount_cents: 2500, currency: "myr", interval: "month" })) do
      get "/subscription", headers: auth(@subscriber)
    end

    assert_response :success
    assert_equal true, body["subscription"]["premium"]
    assert_equal "active", body["subscription"]["status"]
    assert_equal true, body["subscription"]["manageable"]
  end

  # The page's job is to say which plan the user is on. It can still do that with the price missing,
  # so a Stripe outage must not take the whole page down with it.
  test "still reports the plan status when the price cannot be fetched" do
    stubbing(StripeClient, :fetch_plan, failed(:unavailable)) do
      get "/subscription", headers: auth
    end

    assert_response :success
    assert_nil body["plan"]
    assert_equal false, body["subscription"]["premium"]
  end

  # ── checkout ─────────────────────────────────────────────────────────────────

  # The ordering the whole webhook design rests on: with the customer created first, an invoice
  # event arriving before checkout.session.completed still resolves to a user.
  test "creates the Stripe customer before the checkout session" do
    order = []
    stubs = {
      ensure_customer: ->(user) {
        order << :ensure_customer
        user.update!(stripe_customer_id: "cus_new")
        ok("cus_new")
      },
      create_checkout_session: ->(**) {
        order << :create_checkout_session
        ok(stripe_object(url: "https://checkout.stripe.com/c/pay/cs_test_123"))
      }
    }

    stubbing_all(StripeClient, stubs) { post "/subscription/checkout", headers: auth, as: :json }

    assert_response :success
    assert_equal [ :ensure_customer, :create_checkout_session ], order
    assert_equal "https://checkout.stripe.com/c/pay/cs_test_123", body["url"]
    assert_equal "cus_new", @user.reload.stripe_customer_id
  end

  test "refuses a second subscription for an already premium account, without calling Stripe" do
    stubbing_all(StripeClient, { ensure_customer: refusing_to_call, create_checkout_session: refusing_to_call }) do
      post "/subscription/checkout", headers: auth(@subscriber), as: :json
    end

    assert_response :unprocessable_entity
    assert_includes body["errors"].join, "already subscribed"
  end

  test "reports being rate limited as its own answer" do
    stubbing(StripeClient, :ensure_customer, failed(:rate_limited)) do
      post "/subscription/checkout", headers: auth, as: :json
    end

    assert_response :too_many_requests
  end

  test "reports Stripe being unreachable as a bad gateway" do
    stubbing(StripeClient, :ensure_customer, failed(:unavailable)) do
      post "/subscription/checkout", headers: auth, as: :json
    end

    assert_response :bad_gateway
  end

  # ── portal ───────────────────────────────────────────────────────────────────

  test "refuses the billing portal to an account that has never checked out" do
    stubbing(StripeClient, :create_portal_session, refusing_to_call) do
      post "/subscription/portal", headers: auth, as: :json
    end

    assert_response :unprocessable_entity
  end

  test "returns a billing portal URL for a subscriber" do
    portal = ok(stripe_object(url: "https://billing.stripe.com/p/session/test_123"))
    stubbing(StripeClient, :create_portal_session, portal) do
      post "/subscription/portal", headers: auth(@subscriber), as: :json
    end

    assert_response :success
    assert_equal "https://billing.stripe.com/p/session/test_123", body["url"]
  end

  # ── confirm ──────────────────────────────────────────────────────────────────

  test "confirming a checkout applies the subscription" do
    session = ok(stripe_object(client_reference_id: @user.user_id.to_s, subscription: "sub_new"))
    stubs = {
      retrieve_session: session,
      retrieve_subscription: ok(subscription_object(id: "sub_new", status: "active"))
    }

    stubbing_all(StripeClient, stubs) do
      post "/subscription/confirm", params: { session_id: "cs_test_1" }, headers: auth, as: :json
    end

    assert_response :success
    assert_equal true, body["subscription"]["premium"]
    assert_equal "sub_new", @user.reload.stripe_subscription_id
    assert_equal "active", @user.subscription_status
  end

  # Without the client_reference_id check a user could paste someone else's session id and be handed
  # their subscription.
  test "refuses a checkout session belonging to another account, and applies nothing" do
    session = ok(stripe_object(client_reference_id: @subscriber.user_id.to_s, subscription: "sub_theirs"))

    stubbing_all(StripeClient, { retrieve_session: session, retrieve_subscription: refusing_to_call }) do
      post "/subscription/confirm", params: { session_id: "cs_test_1" }, headers: auth, as: :json
    end

    assert_response :forbidden
    assert_nil @user.reload.stripe_subscription_id
  end

  test "confirming without a session id is unprocessable, without calling Stripe" do
    stubbing(StripeClient, :retrieve_session, refusing_to_call) do
      post "/subscription/confirm", params: {}, headers: auth, as: :json
    end

    assert_response :unprocessable_entity
  end

  # ── webhook ──────────────────────────────────────────────────────────────────

  # An unsigned or mis-signed request is indistinguishable from an attacker asking to be made
  # premium, so it must be refused before anything in the payload is read.
  test "a webhook with a bad signature is refused and writes nothing" do
    stubbing(StripeClient, :construct_event, failed(:invalid_signature)) do
      assert_no_difference -> { Payment.count } do
        post "/subscription/webhook",
          params: { type: "invoice.paid", data: { object: { id: "in_forged" } } }.to_json,
          headers: { "Content-Type" => "application/json", "Stripe-Signature" => "t=1,v1=nonsense" }
      end
    end

    assert_response :bad_request
  end

  test "checkout.session.completed applies the subscription to the user it names" do
    event = event_object("checkout.session.completed", stripe_object(
      client_reference_id: @user.user_id.to_s, customer: "cus_new", subscription: "sub_new"
    ))

    stubbing(StripeClient, :retrieve_subscription, ok(subscription_object(id: "sub_new"))) do
      send_webhook(event)
    end

    assert_response :success
    assert_equal "sub_new", @user.reload.stripe_subscription_id
    assert @user.premium?
  end

  test "customer.subscription.deleted leaves the account no longer premium" do
    event = event_object("customer.subscription.deleted", subscription_object(
      id: "sub_fixture_subscriber", status: "canceled", customer: "cus_fixture_subscriber"
    ))

    send_webhook(event)

    assert_response :success
    assert_equal "canceled", @subscriber.reload.subscription_status
    assert_not @subscriber.premium?
  end

  test "customer.subscription.updated records the new period end" do
    period_end = 45.days.from_now.to_i
    event = event_object("customer.subscription.updated", subscription_object(
      id: "sub_fixture_subscriber", status: "active", period_end: period_end, customer: "cus_fixture_subscriber"
    ))

    send_webhook(event)

    assert_response :success
    assert_equal period_end, @subscriber.reload.subscription_period_end.to_i
  end

  test "invoice.paid records the payment" do
    event = event_object("invoice.paid", invoice_object(id: "in_paid_1"))

    assert_difference -> { Payment.count }, 1 do
      send_webhook(event)
    end

    assert_response :success
    payment = Payment.find_by(stripe_invoice_id: "in_paid_1")
    assert_equal @subscriber.user_id, payment.user_id
    assert_equal 2500, payment.amount_cents
    assert_equal "myr", payment.currency
    assert_equal "paid", payment.status
    assert payment.paid_at.present?
  end

  # Stripe delivers at least once and replays anything that does not answer 2xx, so the same invoice
  # arriving twice must leave one row rather than two.
  test "the same invoice delivered twice records one payment" do
    event = event_object("invoice.paid", invoice_object(id: "in_repeat"))

    assert_difference -> { Payment.count }, 1 do
      send_webhook(event)
      send_webhook(event)
    end

    assert_response :success
  end

  # A failure is the earliest signal of a subscription about to lapse, which is why it is recorded
  # rather than dropped -- and it records what was *attempted*, since amount_paid is 0.
  test "invoice.payment_failed records a failed payment with no paid_at" do
    event = event_object("invoice.payment_failed", invoice_object(
      id: "in_failed_1", amount_paid: 0, amount_due: 2500, paid_at: nil
    ))

    assert_difference -> { Payment.count }, 1 do
      send_webhook(event)
    end

    payment = Payment.find_by(stripe_invoice_id: "in_failed_1")
    assert_equal "failed", payment.status
    assert_equal 2500, payment.amount_cents
    assert_nil payment.paid_at
  end

  # Stripe retries anything that does not answer 2xx, so an event this app has no use for has to be
  # accepted rather than treated as a failure and redelivered for days.
  test "an event type with no handler is accepted and changes nothing" do
    event = event_object("customer.updated", stripe_object(id: "cus_fixture_subscriber"))

    assert_no_difference -> { Payment.count } do
      send_webhook(event)
    end

    assert_response :success
  end

  # A webhook for an account this environment has never seen -- another developer sharing the same
  # Stripe test key -- is not an error.
  test "an invoice for an unknown customer is accepted and recorded against nobody" do
    event = event_object("invoice.paid", invoice_object(id: "in_stranger", customer: "cus_never_seen"))

    assert_no_difference -> { Payment.count } do
      send_webhook(event)
    end

    assert_response :success
  end
end
