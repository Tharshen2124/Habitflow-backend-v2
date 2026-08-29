class User < ApplicationRecord
  self.primary_key = "user_id"

  # Declaration order is destroy order. Tasks reference everything, so they go first. Weekly plans
  # come next because destroying one clears that week's goals -- and goals have to be gone before
  # roles are destroyed, since Role deliberately no longer destroys them.
  has_many :tasks, foreign_key: "user_id", primary_key: "user_id", dependent: :destroy
  has_many :weekly_plans, foreign_key: "user_id", primary_key: "user_id", dependent: :destroy
  has_many :roles, foreign_key: "user_id", primary_key: "user_id", dependent: :destroy
  has_many :sharpen_the_saw_activities, foreign_key: "user_id", primary_key: "user_id", dependent: :destroy
  # Position is free, unlike everything above it: payments reference only the user and nothing
  # references payments, so no other association has to be gone before or after this one. Destroyed
  # with the account because the foreign key would otherwise refuse to let it go.
  has_many :payments, foreign_key: "user_id", primary_key: "user_id", dependent: :destroy

  has_secure_password validations: false

  normalizes :email, with: ->(email) { email.to_s.strip.downcase }

  validates :email, presence: true, uniqueness: { case_sensitive: false },
                     format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :username, presence: true, uniqueness: true, length: { minimum: 3, maximum: 30 }
  # Signup is the only way an account is created and it always sets a password, so nothing new can
  # reach the `google_uid.present?` branch. It stays for the rows that predate that rule: making the
  # presence check unconditional would leave those accounts unsaveable, and the OAuth callback
  # writes to the row on every sign-in.
  validates :password_digest, presence: true, if: -> { google_uid.blank? }
  validates :password, length: { minimum: 8 }, allow_blank: true
  # A `time` column casts anything it cannot parse to nil, so without this a malformed "HH:MM"
  # would surface as a not-null violation rather than a 422.
  validates :eod_time, presence: true

  def self.human_attribute_name(attr, options = {})
    if attr.to_s == "password_digest"
      attr = :password
      options = options.merge(default: "Password") if options.key?(:default)
    end
    super(attr, options)
  end

  # Connected means "we hold a refresh token and a calendar to write into". The access token is
  # deliberately not part of the question: it expires every hour and CalendarAccess mints a new one
  # on demand, so treating an expired one as disconnected would log the user out of the feature
  # hourly.
  def calendar_connected?
    calendar_refresh_token.present? && calendar_id.present?
  end

  # Used by both the explicit Disconnect button and CalendarAccess, which reaches it when Google
  # says the grant is gone. Leaves calendar_sync_enabled alone: it is a preference, and a user who
  # reconnects should not have to re-tick a switch they never touched.
  def disconnect_calendar!
    update!(
      calendar_id: nil,
      calendar_access_token: nil,
      calendar_refresh_token: nil,
      calendar_token_expires_at: nil,
      calendar_synced_at: nil
    )
  end

  # Stripe's own statuses that mean the subscription is live and should be treated as paid for.
  PREMIUM_STATUSES = %w[active trialing].freeze

  # Premium means "Stripe says this subscription is live, and the period it paid for has not run
  # out". The second half is not redundant with the first: cancelling sets cancel_at_period_end and
  # leaves the status "active" until the period actually ends, so a single missed webhook on that
  # day would otherwise leave a lapsed account premium forever. Nothing gates on this yet -- it is
  # the predicate the feature limits will read when they are built.
  def premium?
    PREMIUM_STATUSES.include?(subscription_status) &&
      (subscription_period_end.nil? || subscription_period_end > Time.current)
  end

  # Deliberately NOT part of to_token_payload below. That token lives seven days in a cookie, and a
  # subscription can lapse in minutes; a claim that cannot be revoked would say "premium" long after
  # Stripe stopped agreeing. is_onboarded is safe there only because onboarding is one-way.

  # Non-sensitive claims embedded in the JWT so the frontend can decode them client-side.
  def to_token_payload
    { user_id: user_id, email: email, username: username, is_onboarded: is_onboarded }
  end

  # Google is a way *into* an account, never a way to open one -- an account is created only through
  # /signup, which asks for an email, a username and a password. So this finds and links; it never
  # creates. First Google sign-in on an account signed up for by email links the two by email, which
  # is what makes both ways in work from then on. Returns nil when neither the Google id nor the
  # email is known, and the callback turns that into an error rather than a session.
  def self.link_google_account(google_uid:, email:)
    if (user = find_by(google_uid: google_uid))
      return user
    end

    find_by("lower(email) = ?", email.to_s.downcase)&.tap { |u| u.update!(google_uid: google_uid) }
  end
end
