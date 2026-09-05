module Authenticatable
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_request!
  end

  private

  def authenticate_request!
    token = request.headers["Authorization"]&.split(" ")&.last
    payload = token && JsonWebToken.decode(token)
    @current_user = payload && User.find_by(user_id: payload[:user_id])
    return render json: { error: "Unauthorized" }, status: :unauthorized unless @current_user

    # Checked here rather than left to the login endpoints alone. A token lives seven days in a
    # cookie, so a ban that only closed the front door would leave someone who signed in yesterday
    # with a week of full access -- and "banned from using HabitFlow" would be untrue for most of
    # that week. Read off the column on every request, for the reason `premium?` is not a claim
    # either: it has to take effect now, not when the token expires.
    render_banned(@current_user) if @current_user.is_banned?
  end

  def current_user
    @current_user
  end
end
