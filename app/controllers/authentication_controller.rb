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
    # Before the token write below, not after: a banned account is not signing in, so there is no
    # reason to refresh the Google grant it is no longer allowed to use.
    return redirect_banned(user) if user.is_banned?

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
    unless user&.password_digest.present? && user.authenticate(params[:password])
      return render json: { error: "Invalid email or password" }, status: :unauthorized
    end

    # Only once the password has been verified. Asking the column first would let anyone type an
    # address into the form and be told both that it is banned and who to write to about it, which
    # is an account-enumeration oracle bought for no gain -- the person being banned knows their own
    # password.
    return render_banned(user) if user.is_banned?

    render json: { token: JsonWebToken.encode(user.to_token_payload) }, status: :ok
  end

  def redirect_to_google
    state = JsonWebToken.encode({ purpose: STATE_PURPOSE }, exp: 5.minutes.from_now)
    redirect_to GoogleOauthClient.authorization_url(state), allow_other_host: true
  end

  # `render_banned`'s twin for the OAuth road home, which cannot answer with a body. The notice
  # travels in the fragment exactly as the session token does, so the login page has one place that
  # turns a ban into its dialog no matter which door the user came through.
  def redirect_banned(user)
    notice = { error: ApplicationController::BANNED_CODE, email: user.email,
               contact: ENV.fetch("ADMIN_CONTACT_EMAIL") }
    redirect_to "#{ENV.fetch('FRONTEND_ORIGIN')}/login##{notice.to_query}", allow_other_host: true
  end

  def redirect_with_error(code)
    redirect_to "#{ENV.fetch('FRONTEND_ORIGIN')}/login#error=#{code}", allow_other_host: true
  end

  def signup_params
    params.permit(:email, :username, :password)
  end
end
