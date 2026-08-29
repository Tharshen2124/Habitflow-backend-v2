require "stripe"

# Every call this app makes to Stripe, and the only place the gem is named.
#
# It exists for two reasons. The tests replace these methods wholesale through `stubbing`, so no
# test ever constructs a Stripe object or touches the network -- the same seam GeminiSummaryClient
# leaves as `.post` and GoogleCalendarClient as its six request methods. And every failure is
# reduced here to a symbol the controller can map to a message, so nothing above this file has to
# know Stripe's exception hierarchy.
#
# Unlike the Google clients this one wraps a gem rather than Net::HTTP; the Gemfile says why.
class StripeClient
  # What a call produced, or the reason it produced nothing. `error` is nil on success and otherwise
  # one of :rate_limited, :invalid_signature or :unavailable.
  Result = Data.define(:value, :error) do
    def ok? = error.nil?
  end

  class << self
    # The Customer is created *before* the Checkout session rather than being left to
    # `checkout.session.completed`, which is what makes the webhooks tractable: from this moment on
    # users.stripe_customer_id is set, so an invoice event arriving out of order still resolves to a
    # user. Idempotent -- an account that already has one is left alone.
    def ensure_customer(user)
      return Result.new(value: user.stripe_customer_id, error: nil) if user.stripe_customer_id.present?

      call do
        customer = with_key { Stripe::Customer.create(email: user.email, metadata: { user_id: user.user_id }) }
        user.update!(stripe_customer_id: customer.id)
        customer.id
      end
    end

    # client_reference_id is what lets the redirect confirm prove the session belongs to whoever is
    # asking. Without it a user could paste someone else's session id and be handed their plan.
    def create_checkout_session(user:, success_url:, cancel_url:)
      call do
        with_key do
          Stripe::Checkout::Session.create(
            mode: "subscription",
            customer: user.stripe_customer_id,
            client_reference_id: user.user_id.to_s,
            line_items: [ { price: ENV.fetch("STRIPE_PRICE_ID"), quantity: 1 } ],
            success_url: success_url,
            cancel_url: cancel_url
          )
        end
      end
    end

    # Cancel, resume, change card and download invoices, all hosted by Stripe. Building any of it
    # here would mean reimplementing a flow Stripe keeps correct for free.
    def create_portal_session(user:, return_url:)
      call { with_key { Stripe::BillingPortal::Session.create(customer: user.stripe_customer_id, return_url: return_url) } }
    end

    def retrieve_session(session_id)
      call { with_key { Stripe::Checkout::Session.retrieve(session_id) } }
    end

    def retrieve_subscription(subscription_id)
      call { with_key { Stripe::Subscription.retrieve(subscription_id) } }
    end

    # What the plan costs, read from Stripe rather than hardcoded, so the price on the pricing page
    # can never disagree with the price on the card form. One request, on a page nobody reloads.
    def fetch_plan
      call do
        price = with_key { Stripe::Price.retrieve(ENV.fetch("STRIPE_PRICE_ID")) }
        {
          amount_cents: price.unit_amount,
          currency: price.currency,
          interval: price.recurring&.interval
        }
      end
    end

    # Every invoice Stripe holds for one customer, paged through in full.
    #
    # The only call in this file that *asks* about invoices; everywhere else this app is told about
    # them, by a webhook. It exists for BackfillStripePayments, which catches an environment up
    # after the webhook was not being delivered -- see that service for why that happens at all.
    def list_invoices(customer_id)
      call { with_key { Stripe::Invoice.list(customer: customer_id, limit: 100).auto_paging_each.to_a } }
    end

    # The security boundary. Verifies the signature over the *raw* body and returns the parsed event
    # only if it holds -- an unsigned or mis-signed request is indistinguishable from an attacker
    # asking to be made premium.
    def construct_event(payload, signature_header)
      call do
        Stripe::Webhook.construct_event(payload, signature_header, ENV.fetch("STRIPE_WEBHOOK_SECRET"))
      end
    end

    private

    # Stripe reads its key from global state, so it is set per call rather than in an initializer:
    # an initializer would raise at boot on a machine with no key, which is every CI run.
    def with_key
      Stripe.api_key = ENV.fetch("STRIPE_SECRET_KEY")
      yield
    end

    def call
      Result.new(value: yield, error: nil)
    rescue Stripe::SignatureVerificationError
      # Logged without the body or the header: one of them is the forgery and the other is the
      # secret's fingerprint, and neither belongs in a log that someone can cause to be written.
      Rails.logger.warn("Stripe webhook signature rejected")
      failure(:invalid_signature)
    rescue Stripe::RateLimitError
      failure(:rate_limited)
    rescue Stripe::StripeError => e
      # Stripe's own message says what was wrong with the request, and it never contains the API
      # key. Without this an upstream failure is a bare 502 with nothing to act on.
      Rails.logger.error("Stripe responded with an error: #{e.message}")
      failure(:unavailable)
    rescue KeyError => e
      # A missing key is a misconfiguration, not an outage, and it fails before any network call.
      # It reads to the user as "unavailable" like everything else, so without this line the only
      # symptom is a fast 502 that looks exactly like a real one.
      Rails.logger.error("StripeClient is not configured: #{e.message}")
      failure(:unavailable)
    rescue StandardError => e
      # A timeout, a socket error, or a record that would not save. There is nothing the user can
      # do differently about any of them, so they all read the same to them.
      Rails.logger.error("Stripe call failed: #{e.class}: #{e.message}")
      failure(:unavailable)
    end

    def failure(error) = Result.new(value: nil, error: error)
  end
end
