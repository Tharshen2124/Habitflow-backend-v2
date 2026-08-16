class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users, id: false do |t|
      t.primary_key :user_id
      t.string :username
      t.string :email
      t.string :password
      t.string :google_access_token
      t.string :google_refresh_token
      t.string :google_uid
      t.datetime :google_token_expires_at
      t.string :google_scope
      t.string :calendar_id
      t.string :export_preference
      t.boolean :is_onboarded, default: false, null: false
      t.boolean :email_notifications_enabled, default: true, null: false
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    add_index :users, :google_uid, unique: true
  end
end
