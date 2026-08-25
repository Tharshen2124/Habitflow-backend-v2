class AddCalendarSyncToUsers < ActiveRecord::Migration[8.1]
  def up
    # Deliberately NOT the google_* columns. AuthenticationController#callback rewrites those on
    # every Google sign-in with the narrow "openid email profile" grant, so sharing them would mean
    # signing in with Google silently revoked calendar access -- with nothing raised anywhere and
    # the next sync failing on a token that no longer carries the scope.
    add_column :users, :calendar_access_token, :string
    add_column :users, :calendar_refresh_token, :string
    add_column :users, :calendar_token_expires_at, :datetime

    # The "Allow Sync Changes" switch on /settings. A column rather than a key inside
    # export_preference: what to export and whether to export at all are different questions, and
    # the auto-sync hooks read this one on every write.
    add_column :users, :calendar_sync_enabled, :boolean, default: true, null: false
    add_column :users, :calendar_synced_at, :datetime

    # export_preference was created with the users table and has never been written -- every row is
    # NULL -- so the cast cannot fail. It holds a set of exclusions, which a bare string cannot.
    change_column :users, :export_preference, :jsonb, using: "export_preference::jsonb"
  end

  def down
    change_column :users, :export_preference, :string, using: "export_preference::text"
    remove_column :users, :calendar_synced_at
    remove_column :users, :calendar_sync_enabled
    remove_column :users, :calendar_token_expires_at
    remove_column :users, :calendar_refresh_token
    remove_column :users, :calendar_access_token
  end
end
