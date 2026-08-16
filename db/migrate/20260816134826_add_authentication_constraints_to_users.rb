class AddAuthenticationConstraintsToUsers < ActiveRecord::Migration[8.1]
  def change
    rename_column :users, :password, :password_digest
    change_column_null :users, :email, false
    change_column_null :users, :username, false
    add_index :users, "lower(email)", unique: true, name: "index_users_on_lower_email"
    add_index :users, :username, unique: true
  end
end
