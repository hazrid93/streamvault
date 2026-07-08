# frozen_string_literal: true

# Kick off the background cache warmer shortly after boot so the first
# real user visit hits a warm cache.  Uses a detached Ruby Thread (the
# deployment runs a single web process with no separate SolidQueue
# worker — matching the existing Thread.new pattern in HomeController).
#
# The 10s delay lets the web server finish binding its port and run
# db:prepare before the warmer starts hitting upstream APIs, so a cold
# boot doesn't compete with serving the first request.
Rails.application.config.after_initialize do
  # Only warm in the web server process (not in rails console, assets
  # precompilation, migrations, or rake tasks), and only when explicitly
  # enabled (default on) so it can be disabled for one-off runs.
  if ENV["DISABLE_CACHE_WARMER"] != "true" &&
     defined?(Rails::Server) && Rails.application.config.cache_classes
    Thread.new do
      sleep 10
      begin
        Rails.logger.info("[CacheWarmer] starting background cache pre-warm")
        CacheWarmer.new.warm_all
        Rails.logger.info("[CacheWarmer] background cache pre-warm complete")
      rescue => e
        Rails.logger.error("[CacheWarmer] pre-warm failed: #{e.message}")
      end
    end
  end
end