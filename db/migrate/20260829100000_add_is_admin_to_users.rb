class AddIsAdminToUsers < ActiveRecord::Migration[8.1]
  def change
    # An admin is an ordinary HabitFlow account with one extra permission, which is why this is a
    # column rather than an `admins` table: a separate table would mean a second login page, a
    # second token shape and a second authentication concern, all for the same credentials.
    #
    # Granted by hand -- `User.find_by(email: ...).update!(is_admin: true)` -- and deliberately not
    # by any endpoint. The only account that could call a "promote" action is already an admin, and
    # the flag is set perhaps once in the life of a deployment, so an endpoint would be a permanent
    # privilege-escalation surface bought for nothing.
    #
    # No index: nothing queries `where(is_admin: true)`. The flag is read one row at a time, off the
    # user the bearer token already resolved to.
    add_column :users, :is_admin, :boolean, default: false, null: false
  end
end
