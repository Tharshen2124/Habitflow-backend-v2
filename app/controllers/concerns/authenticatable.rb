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
    render json: { error: "Unauthorized" }, status: :unauthorized unless @current_user
  end

  def current_user
    @current_user
  end
end
