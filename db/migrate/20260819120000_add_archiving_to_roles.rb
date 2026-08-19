class AddArchivingToRoles < ActiveRecord::Migration[8.1]
  def change
    # Roles are referenced by goals in every week they were ever used, and analytics resolves a
    # task's role through goal -> role. Removing the row would break every past week, so a role is
    # archived instead. A timestamp rather than a boolean: the UI shows when it was archived.
    add_column :roles, :deleted_at, :datetime

    # The frontend has always had a per-role colour with no column behind it, and /history renders
    # a role colour against each past goal.
    add_column :roles, :color_id, :string
    add_column :roles, :updated_at, :datetime, null: false, default: -> { "CURRENT_TIMESTAMP" }

    remove_index :roles, :user_id
    add_index :roles, [ :user_id, :deleted_at ]
  end
end
