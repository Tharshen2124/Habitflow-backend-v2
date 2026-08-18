class AddIsDeletedToSharpenTheSawActivities < ActiveRecord::Migration[8.1]
  def change
    add_column :sharpen_the_saw_activities, :is_deleted, :boolean, null: false, default: false

    remove_index :sharpen_the_saw_activities, :user_id
    add_index :sharpen_the_saw_activities, [ :user_id, :is_deleted ]
  end
end
