require "net/http"

class GoogleOauthClient
  AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
  TOKEN_URL = "https://oauth2.googleapis.com/token"
  USERINFO_URL = "https://www.googleapis.com/oauth2/v3/userinfo"

  def self.authorization_url(state)
    params = {
      client_id: ENV.fetch("GOOGLE_OAUTH_CLIENT_ID"),
      redirect_uri: ENV.fetch("GOOGLE_OAUTH_REDIRECT_URI"),
      response_type: "code",
      scope: "openid email profile",
      access_type: "offline",
      prompt: "consent",
      state: state
    }
    "#{AUTH_URL}?#{params.to_query}"
  end

  def self.exchange_code_for_tokens(code)
    response = Net::HTTP.post_form(URI(TOKEN_URL), {
      code: code,
      client_id: ENV.fetch("GOOGLE_OAUTH_CLIENT_ID"),
      client_secret: ENV.fetch("GOOGLE_OAUTH_CLIENT_SECRET"),
      redirect_uri: ENV.fetch("GOOGLE_OAUTH_REDIRECT_URI"),
      grant_type: "authorization_code"
    })
    response.is_a?(Net::HTTPSuccess) ? JSON.parse(response.body) : nil
  end

  def self.fetch_profile(access_token)
    uri = URI(USERINFO_URL)
    req = Net::HTTP::Get.new(uri).tap { |r| r["Authorization"] = "Bearer #{access_token}" }
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
    response.is_a?(Net::HTTPSuccess) ? JSON.parse(response.body) : nil
  end
end
