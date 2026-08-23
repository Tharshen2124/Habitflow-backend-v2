class User < ApplicationRecord
  self.primary_key = "user_id"

  # Declaration order is destroy order. Tasks reference everything, so they go first. Weekly plans
  # come next because destroying one clears that week's goals -- and goals have to be gone before
  # roles are destroyed, since Role deliberately no longer destroys them.
  has_many :tasks, foreign_key: "user_id", primary_key: "user_id", dependent: :destroy
  has_many :weekly_plans, foreign_key: "user_id", primary_key: "user_id", dependent: :destroy
  has_many :roles, foreign_key: "user_id", primary_key: "user_id", dependent: :destroy
  has_many :sharpen_the_saw_activities, foreign_key: "user_id", primary_key: "user_id", dependent: :destroy

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
