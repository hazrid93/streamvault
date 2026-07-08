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

  # A label/value row used inside <dl>.
  def stat_row(label, value)
    tag.dt(label, class: "text-sv-text-muted inline") +
      " " +
      tag.dd(value.to_s, class: "text-white inline float-right")
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