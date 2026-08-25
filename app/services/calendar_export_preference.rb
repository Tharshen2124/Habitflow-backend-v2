# Which of a week's tasks reach Google Calendar.
#
# Stored as *exclusions*, keyed by role_id and dimension id, because the alternative fails the one
# thing this has to survive: roles change. An inclusion list keyed by name breaks on the first
# rename; keyed by id it still leaves a role created after the preferences were saved silently
# unexported, with nothing on screen to explain why. Recording only what the user has switched off
# means a rename keeps its setting, a new role exports by default -- matching the settings tree,
# where every leaf starts ticked -- and an archived role leaves an id behind that harms nothing.
class CalendarExportPreference
  DEFAULTS = { "fixed_appointments" => true, "excluded_dimensions" => [], "excluded_role_ids" => [] }.freeze

  def initialize(raw)
    stored = raw.is_a?(Hash) ? raw : {}
    # Cast rather than compare: jsonb round-trips a real boolean, but a form-encoded client sends
    # the string "false", and `"false" != false` is true -- which would turn the switch off in the
    # UI and leave it on in the export.
    fixed = stored["fixed_appointments"]
    @fixed_appointments = fixed.nil? ? true : ActiveModel::Type::Boolean.new.cast(fixed) == true
    @excluded_dimensions = Array(stored["excluded_dimensions"]).map(&:to_s)
    @excluded_role_ids = Array(stored["excluded_role_ids"]).map(&:to_i)
  end

  # Takes whatever /settings sent and keeps only the three keys, in the right types. The column is
  # jsonb, so without this a client could store anything at all in it.
  def self.sanitise(params)
    new(
      "fixed_appointments" => params["fixed_appointments"],
      "excluded_dimensions" => params["excluded_dimensions"],
      "excluded_role_ids" => params["excluded_role_ids"]
    ).to_h
  end

  def exports?(task)
    return @fixed_appointments if task.is_fixed_appointment?
    return !@excluded_role_ids.include?(task.goal.role_id) if task.goal_id.present?
    return !@excluded_dimensions.include?(task.sharpen_the_saw_activity.dimension) if task.sharpen_the_saw_activity_id.present?

    # A task with no goal, no activity and no fixed-appointment flag. Every planning surface makes a
    # task pick one of the two links, so this is only reachable through the API directly -- there is
    # no category in the settings tree to hang it under, and inventing one to hide a state the UI
    # cannot produce would be worse than exporting it.
    true
  end

  def to_h
    {
      "fixed_appointments" => @fixed_appointments,
      "excluded_dimensions" => @excluded_dimensions,
      "excluded_role_ids" => @excluded_role_ids
    }
  end
end
