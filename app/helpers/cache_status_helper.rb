# frozen_string_literal: true

module CacheStatusHelper
  # Coloured pill for a warmer state + thread liveness.
  def state_badge(state, thread_alive = nil)
    label, tone = case state.to_sym
                  when :running then ["running", :accent]
                  when :complete then ["complete", :success]
                  when :failed then ["failed", :danger]
                  when :pending then ["pending", :warning]
                  else ["idle", nil]
                  end
    classes = "px-2 py-0.5 rounded-full text-xs font-medium border"
    bg = case tone
         when :accent then "bg-sv-accent/15 text-sv-accent border-sv-accent/30"
         when :success then "bg-sv-success/15 text-sv-success border-sv-success/30"
         when :danger then "bg-sv-danger/15 text-sv-danger border-sv-danger/30"
         when :warning then "bg-sv-warning/15 text-sv-warning border-sv-warning/30"
         else "bg-sv-bg text-sv-text-muted border-sv-border"
         end
    suffix = thread_alive.nil? ? "" : (thread_alive ? " • live" : " • stale")
    tag.span(label + suffix, class: "#{classes} #{bg}")
  end

  # A label/value row used inside the warmer status cards.  Uses flex
  # justify-between instead of float-right (which overlaps on mobile).
  def stat_row(label, value)
    tag.div(class: "flex items-center justify-between gap-2") do
      tag.span(label, class: "text-sv-text-muted text-xs sm:text-sm shrink-0") +
        tag.span(value.to_s, class: "text-white text-xs sm:text-sm text-right truncate")
    end
  end

  def time_ago(time)
    return "—" unless time
    "#{time_ago_in_words(time)} ago"
  end

  def duration_ms(ms)
    return "—" unless ms
    ms < 1000 ? "#{ms} ms" : "#{(ms / 1000.0).round(1)} s"
  end

  def next_run_in(time)
    return "—" unless time
    if time > Time.current
      "in #{time_ago_in_words(time)}"
    else
      "due #{time_ago_in_words(time)} ago"
    end
  end

  def humanize_duration(seconds)
    if seconds >= 1.hour
      h = (seconds / 1.hour).to_i
      h == 1 ? "1 hour" : "#{h} hours"
    elsif seconds >= 1.minute
      m = (seconds / 1.minute).to_i
      m == 1 ? "1 minute" : "#{m} minutes"
    else
      "#{seconds.to_i}s"
    end
  end
end