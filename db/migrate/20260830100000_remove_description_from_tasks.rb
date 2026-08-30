# `tasks.description` was only ever a fixed appointment's optional notes: `create_scheduled_tasks`
# never permitted the field, so every other task in the table sat at NULL. The notes field is gone
# from the three calendars that offered it, which leaves the column with nothing to hold.
class RemoveDescriptionFromTasks < ActiveRecord::Migration[8.1]
  def change
    remove_column :tasks, :description, :string
  end
end
