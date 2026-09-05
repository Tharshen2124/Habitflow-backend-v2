class AddIsBannedToUsers < ActiveRecord::Migration[8.1]
  def change
    # A ban is a column on the account for the same reason `is_admin` is: it is one extra fact about
    # an ordinary HabitFlow account, not a second kind of account. A `bans` table would buy a reason,
    # an expiry and an audit trail, none of which the dashboard's one toggle has anything to say.
    #
    # Deliberately not part of `to_token_payload`. A token lives seven days in a cookie, so a claim
    # would leave a banned account working for the rest of the week -- the same trap `premium?`
    # avoids by staying off the token. It is read off this column on every authenticated request.
    #
    # No index: nothing queries `where(is_banned: true)`. It is read one row at a time, off the user
    # the bearer token or the login form already resolved to.
    add_column :users, :is_banned, :boolean, default: false, null: false
  end
end
