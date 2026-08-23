# Frees yellow from the role palette so it can mean one thing on a calendar.
#
# Yellow (`"accent"`, #FFCC00) is now reserved for a task under a goal the user named a weekly
# priority. A role that could still claim it would leave a yellow card ambiguous, so the id is gone
# from the frontend palette and the rows that hold it are reassigned here.
#
# The model class is declared locally rather than reused from app/models, for the reason
# BackfillWeeklyPlans gives: a migration has to keep working against the schema as it was here.
class RetireYellowRoleColor < ActiveRecord::Migration[8.1]
  class Role < ApplicationRecord
    self.table_name = "roles"
    self.primary_key = "role_id"
  end

  # The palette as it now stands, in the order the picker offers it.
  PALETTE = %w[primary secondary teal rose orange].freeze
  RETIRED = "accent".freeze

  # Orange is the fallback rather than the first of the list: it is the nearest thing left to the
  # yellow being taken away, so a user whose palette is already full sees the smallest change.
  FALLBACK = "orange".freeze

  def up
    Role.where(color_id: RETIRED).find_each do |role|
      # Archived roles count as taken. They keep their colour through a restore, so ignoring them
      # would let a restored role collide with the one reassigned here.
      taken = Role.where(user_id: role.user_id)
                  .where.not(role_id: role.role_id)
                  .distinct.pluck(:color_id).compact

      role.update_columns(color_id: PALETTE.find { |c| taken.exclude?(c) } || FALLBACK)
    end
  end

  # Which roles were yellow is exactly what this migration spends, and nothing else records it.
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
