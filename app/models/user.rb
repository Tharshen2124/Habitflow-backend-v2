class User < ApplicationRecord
  self.primary_key = "user_id"

  has_secure_password validations: false

  normalizes :email, with: ->(email) { email.to_s.strip.downcase }

  validates :email, presence: true, uniqueness: { case_sensitive: false },
                     format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :username, presence: true, uniqueness: true, length: { minimum: 3, maximum: 30 }
  validates :password_digest, presence: true, if: -> { google_uid.blank? }
  validates :password, length: { minimum: 8 }, allow_blank: true

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

  def self.find_or_create_from_google!(google_uid:, email:, name:)
    if (user = find_by(google_uid: google_uid))
      return user
    end

    if (user = find_by("lower(email) = ?", email.to_s.downcase))
      user.update!(google_uid: google_uid)
      return user
    end

    base_username = name.presence || email.to_s.split("@").first
    username = base_username
    username = "#{base_username}#{SecureRandom.hex(2)}" while exists?([ "lower(username) = ?", username.downcase ])

    create!(google_uid: google_uid, email: email, username: username, password: nil)
  end
end
