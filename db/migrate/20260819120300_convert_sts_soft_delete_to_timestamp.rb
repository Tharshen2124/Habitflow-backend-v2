class ConvertStsSoftDeleteToTimestamp < ActiveRecord::Migration[8.1]
  # Roles and goals archive with a `deleted_at` timestamp. Moving activities onto the same idiom
  # keeps one soft-delete convention in the schema instead of two.
  def up
    add_column :sharpen_the_saw_activities, :deleted_at, :datetime
    execute <<~SQL
      UPDATE sharpen_the_saw_activities
      SET deleted_at = CURRENT_TIMESTAMP
      WHERE is_deleted = TRUE
    SQL

    remove_index :sharpen_the_saw_activities, [ :user_id, :is_deleted ]
    remove_column :sharpen_the_saw_activities, :is_deleted
    add_index :sharpen_the_saw_activities, [ :user_id, :deleted_at ]
  end

  def down
    add_column :sharpen_the_saw_activities, :is_deleted, :boolean, null: false, default: false
    execute <<~SQL
      UPDATE sharpen_the_saw_activities
      SET is_deleted = TRUE
      WHERE deleted_at IS NOT NULL
    SQL

    remove_index :sharpen_the_saw_activities, [ :user_id, :deleted_at ]
    remove_column :sharpen_the_saw_activities, :deleted_at
    add_index :sharpen_the_saw_activities, [ :user_id, :is_deleted ]
  end
end
