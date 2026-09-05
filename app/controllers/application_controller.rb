class ApplicationController < ActionController::API
  # The machine-readable name for a ban, sent in the body beside the status.
  #
  # The status itself stays 403, because that is what a ban is -- authenticated, and not allowed.
  # But 403 already means two other things here (not an administrator, and a checkout session
  # belonging to somebody else), so the status alone cannot tell the client which refusal it is
  # holding. A ban is the one that has something specific to say: which account, and who to write
  # to. Hence a code, read by `next-app/lib/api.ts`, rather than a fourth status.
  BANNED_CODE = "banned".freeze

  private

  # Shared by the two doors a banned account can arrive at: the login endpoints, and every
  # authenticated request through `Authenticatable`.
  #
  # The email is echoed back rather than left to the client to remember, because the ban can land
  # mid-session on a page that never asked anyone to type one -- and the contact address is config
  # the frontend has no second copy of.
  def render_banned(user)
    render json: {
      code: BANNED_CODE,
      error: "This account has been banned",
      email: user.email,
      contact_email: ENV.fetch("ADMIN_CONTACT_EMAIL")
    }, status: :forbidden
  end
end
