class CreateSharpenTheSawActivities < ActiveRecord::Migration[8.1]
  def change
    create_table :sharpen_the_saw_activities, id: false do |t|
      t.primary_key :sharpen_the_saw_activity_id
      t.bigint :user_id, null: false
      t.string :dimension, null: false
      t.string :activity_description, null: false
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    add_index :sharpen_the_saw_activities, :user_id
    add_foreign_key :sharpen_the_saw_activities, :users, column: :user_id, primary_key: :user_id
  end
end
