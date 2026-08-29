class SubscriptionsController < ApplicationController
  include Authenticatable

  # The one action Stripe itself calls. It arrives server-to-server with no bearer token -- the
  # signature over the raw body is what says the request is genuine, and it is checked before
  # anything is read out of the payload.
  skip_before_action :authenticate_request!, only: [ :webhook ]

  # The events that change what this app knows. Anything else is answered 200 and ignored: Stripe
  # retries whatever does not answer 2xx, so treating an event we have no use for as a failure would
  # have it redelivered for days.
  CHECKOUT_COMPLETED = "checkout.session.completed".freeze
  SUBSCRIPTION_CHANGED = [ "customer.subscription.updated", "customer.subscription.created" ].freeze
  SUBSCRIPTION_DELETED = "customer.subscription.deleted".freeze
  INVOICE_PAID = "invoice.paid".freeze
  INVOICE_FAILED = "invoice.payment_failed".freeze

  def show
    plan = StripeClient.fetch_plan
    # The price is worth a request but not worth a failure: the page's job is to say what plan the
    # user is on, and it can still do that with the amount missing.
    render json: { subscription: subscription_json, plan: plan.ok? ? plan.value : nil }
  end

  # Returns the Checkout URL rather than redirecting to it, the same reason calendar#connect does:
  # a redirect must be followed by the browser, and the browser cannot send the bearer token that
  # says whose subscription this is. The frontend asks with its token, then navigates.
  def checkout
    return render_already_subscribed if current_user.premium?

    # Before the session, not after it. From here on users.stripe_customer_id is set, so an invoice
    # webhook that arrives before checkout.session.completed still resolves to a user -- which is
    # how the ordering between those two stops mattering at all.
    customer = StripeClient.ensure_customer(current_user)
    return render_upstream_error(customer.error) unless customer.ok?

    session = StripeClient.create_checkout_session(
      user: current_user,
      success_url: "#{frontend_origin}/subscription?checkout=success&session_id={CHECKOUT_SESSION_ID}",
      cancel_url: "#{frontend_origin}/subscription?checkout=cancelled"
    )
    return render_upstream_error(session.error) unless session.ok?

    render json: { url: session.value.url }
  end

  def portal
    if current_user.stripe_customer_id.blank?
      return render json: { errors: [ "You don't have a subscription to manage yet" ] },
                    status: :unprocessable_entity
    end

    session = StripeClient.create_portal_session(user: current_user, return_url: "#{frontend_origin}/subscription")
    return render_upstream_error(session.error) unless session.ok?

    render json: { url: session.value.url }
  end

  # The redirect half of the truth. The webhook is what this app believes, but it can land seconds
  # after the browser is back, and a user who has just paid should not be looking at a page that
  # says Free. This writes the same state through the same service, so the two cannot disagree.
  def confirm
    return render json: { errors: [ "A checkout session is required" ] }, status: :unprocessable_entity if params[:session_id].blank?

    session = StripeClient.retrieve_session(params[:session_id])
    return render_upstream_error(session.error) unless session.ok?

    # The session names who started it. Without this check a user could paste someone else's session
    # id and be handed their subscription.
    unless session.value.client_reference_id.to_s == current_user.user_id.to_s
      return render json: { errors: [ "That checkout session belongs to another account" ] }, status: :forbidden
    end

    apply_subscription_id(current_user, session.value.subscription)
    render json: { subscription: subscription_json }
  end

  def webhook
    # The raw body, never the parsed params: the signature is over the exact bytes Stripe sent, and
    # a re-serialised hash is not those bytes. `raw_post` caches, so reading it here is safe even
    # though Rails has already parsed the body into params.
    event = StripeClient.construct_event(request.raw_post, request.headers["Stripe-Signature"])
    return head :bad_request unless event.ok?

    handle(event.value)
    head :ok
  end

  private

  def handle(event)
    object = event.data.object

    case event.type
    when CHECKOUT_COMPLETED
      user = User.find_by(user_id: object.client_reference_id) || user_for_customer(object.customer)
      apply_subscription_id(user, object.subscription) if user
    when *SUBSCRIPTION_CHANGED, SUBSCRIPTION_DELETED
      user = user_for_customer(object.customer)
      ApplyStripeSubscription.call(user: user, subscription: object) if user
    when INVOICE_PAID
      record_invoice(object, Payment::PAID)
    when INVOICE_FAILED
      record_invoice(object, Payment::FAILED)
    end
  end

  # Checkout and the confirm both hand back a subscription id rather than the subscription, so it is
  # fetched before being applied. One extra request on the two events a user waits through, in
  # exchange for the status and period end always coming from Stripe rather than being inferred.
  def apply_subscription_id(user, subscription_id)
    return if user.nil? || subscription_id.blank?

    subscription = StripeClient.retrieve_subscription(subscription_id)
    ApplyStripeSubscription.call(user: user, subscription: subscription.value) if subscription.ok?
  end

  def record_invoice(invoice, status)
    user = user_for_customer(invoice.customer)
    RecordStripePayment.call(user: user, invoice: invoice, status: status) if user
  end

  # Every event but the first names a customer and nothing else this app knows, which is why
  # ensure_customer runs before checkout starts. A customer we have never seen is not an error --
  # it is a webhook for an account on another environment sharing the same Stripe test key.
  def user_for_customer(customer)
    id = customer.respond_to?(:id) ? customer.id : customer
    User.find_by(stripe_customer_id: id)
  end

  def render_already_subscribed
    render json: { errors: [ "You're already subscribed to Premium" ] }, status: :unprocessable_entity
  end

  def render_upstream_error(error)
    case error
    when :rate_limited
      render json: { errors: [ "Stripe is busy right now — please try again in a moment." ] },
             status: :too_many_requests
    else
      render json: { errors: [ "Payments are unavailable right now — please try again shortly." ] },
             status: :bad_gateway
    end
  end

  def frontend_origin = ENV.fetch("FRONTEND_ORIGIN")

  def subscription_json
    {
      premium: current_user.premium?,
      status: current_user.subscription_status,
      period_end: current_user.subscription_period_end&.iso8601,
      # Whether there is anything for the Billing Portal to manage. A user who has never checked out
      # has no customer, and the portal has nothing to show them.
      manageable: current_user.stripe_customer_id.present?
    }
  end
end
