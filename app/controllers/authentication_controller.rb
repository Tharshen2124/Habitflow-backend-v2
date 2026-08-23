class AuthenticationController < ApplicationController
  STATE_PURPOSE = "google_oauth_state"

  def signup
    user = User.new(signup_params)
    if user.save
      render json: { user: { email: user.email, username: user.username } }, status: :created
    else
      render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def login
    request.get? || request.head? ? redirect_to_google : password_login
  end

  def callback
    return redirect_with_error("access_denied") if params[:error].present?

    state = params[:state] && JsonWebToken.decode(params[:state])
    return redirect_with_error("invalid_state") unless state && state[:purpose] == STATE_PURPOSE

    tokens = GoogleOauthClient.exchange_code_for_tokens(params[:code])
    return redirect_with_error("token_exchange_failed") unless tokens

    profile = GoogleOauthClient.fetch_profile(tokens["access_token"])
    return redirect_with_error("profile_fetch_failed") unless profile

    # Google signs a user in; it does not sign them up. An address with no account behind it is sent
    # back to /login to create one the ordinary way rather than being handed a session.
    user = User.link_google_account(google_uid: profile["sub"], email: profile["email"])
    return redirect_with_error("no_account") unless user

    user.update!(
      google_access_token: tokens["access_token"],
      google_refresh_token: tokens["refresh_token"].presence || user.google_refresh_token,
      google_token_expires_at: Time.current + tokens["expires_in"].to_i.seconds,
      google_scope: tokens["scope"]
    )

    redirect_to "#{ENV.fetch('FRONTEND_ORIGIN')}/login#token=#{JsonWebToken.encode(user.to_token_payload)}",
                allow_other_host: true
  end

  private

  def password_login
    user = User.find_by("lower(email) = ?", params[:email].to_s.downcase)
    if user&.password_digest.present? && user.authenticate(params[:password])
      render json: { token: JsonWebToken.encode(user.to_token_payload) }, status: :ok
    else
      render json: { error: "Invalid email or password" }, status: :unauthorized
    end
  end

  def redirect_to_google
    state = JsonWebToken.encode({ purpose: STATE_PURPOSE }, exp: 5.minutes.from_now)
    redirect_to GoogleOauthClient.authorization_url(state), allow_other_host: true
  end

  def redirect_with_error(code)
    redirect_to "#{ENV.fetch('FRONTEND_ORIGIN')}/login#error=#{code}", allow_other_host: true
  end

  def signup_params
    params.permit(:email, :username, :password)
  end
end
