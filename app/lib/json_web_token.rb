class JsonWebToken
  ALGORITHM = "HS256"
  DEFAULT_TTL = 7.days

  def self.secret
    Rails.application.secret_key_base
  end

  def self.encode(payload, exp: DEFAULT_TTL.from_now)
    JWT.encode(payload.merge(exp: exp.to_i), secret, ALGORITHM)
  end

  def self.decode(token)
    body = JWT.decode(token, secret, true, algorithm: ALGORITHM).first
    ActiveSupport::HashWithIndifferentAccess.new(body)
  rescue JWT::DecodeError, JWT::ExpiredSignature
    nil
  end
end
