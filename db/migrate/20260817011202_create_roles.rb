class CreateRoles < ActiveRecord::Migration[8.1]
  def change
    create_table :roles, id: false do |t|
      t.primary_key :role_id
      t.bigint :user_id, null: false
      t.string :role_name, null: false
      t.string :icon_id
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    add_index :roles, :user_id
    add_foreign_key :roles, :users, column: :user_id, primary_key: :user_id
  end
end
