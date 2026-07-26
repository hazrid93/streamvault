# frozen_string_literal: true

# Queue one boot warm shortly after the web process starts. Periodic warming
# is scheduled by Solid Queue in config/recurring.yml. Keeping both paths in
# Active Job avoids detached long-lived Ruby threads inside Puma, gives work
# durable execution, and lets CacheWarmerJob's concurrency control prevent a
# deploy-time warm from overlapping a scheduled run.
Rails.application.config.after_initialize do
  next if ENV["DISABLE_CACHE_WARMER"] == "true"
  next unless defined?(Rails::Server) && Rails.application.config.cache_classes

  CacheWarmer.update_status(
    periodic: { next_run_at: Time.current + CacheWarmer::REWARM_INTERVAL }
  )
  CacheWarmerJob.set(wait: 10.seconds).perform_later(false)
rescue StandardError => error
  Rails.logger.error("[CacheWarmer] could not enqueue boot warm: #{error.message}")
end