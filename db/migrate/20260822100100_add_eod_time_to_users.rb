class AddEodTimeToUsers < ActiveRecord::Migration[8.1]
  def change
    # When the End-of-Day check-in appears, alongside the other per-user preferences already on this
    # table. It is a preference rather than an event, which is why it lives here and not in
    # check_ins.
    #
    # A bare `time` with no zone is the point: the server stores no timezone for a user, and 21:00
    # means 21:00 on whichever clock they are reading. The comparison against "now" stays a client
    # decision, exactly as week_start does.
    add_column :users, :eod_time, :time, null: false, default: "21:00"
  end
end
