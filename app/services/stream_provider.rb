# frozen_string_literal: true

# Factory that returns the configured stream provider(s).
#
# STREAM_PROVIDER env var:
#   "comet"     → Comet primary, Torrentio fallback
#   "torrentio" → Torrentio primary (default, backward-compatible)
#   "auto"      → Comet if configured, else Torrentio; Comet first with
#                 Torrentio fallback when both are configured
#
# Each provider implements:
#   streams(imdb_id, type, season:, episode:, title:, preferred_languages:, default_language:)
#     → ServiceResult<Array<Hash>>
#   self.resolve_base_url → String (for ContentStreamingService origin validation)
module StreamProvider
  module_function

  # Returns an ordered array of provider instances configured for the user.
  # The first provider is primary; subsequent ones are fallbacks used when
  # the primary returns no streams or fails to connect.
  def providers(rd_api_key:)
    provider_entries(rd_api_key: rd_api_key).map { |entry| entry.fetch(:service) }
  end

  # Named entries let the UI request each provider independently. Those
  # concurrent Turbo-frame requests render whichever provider answers first
  # instead of making the detail page wait for the slowest provider.
  def provider_entries(rd_api_key:)
    setting = ENV.fetch("STREAM_PROVIDER", "torrentio").to_s.downcase
    entries = []

    case setting
    when "comet"
      entries << { id: "comet", label: "Comet", service: CometService.new(rd_api_key: rd_api_key) } if CometService.comet_url.present?
    when "auto"
      entries << { id: "comet", label: "Comet", service: CometService.new(rd_api_key: rd_api_key) } if CometService.comet_url.present?
      entries << { id: "torrentio", label: "Torrentio", service: TorrentioService.new(rd_api_key: rd_api_key) }
    else
      entries << { id: "torrentio", label: "Torrentio", service: TorrentioService.new(rd_api_key: rd_api_key) }
    end

    entries
  end

  def provider_ids
    provider_entries(rd_api_key: nil).map { |entry| entry.fetch(:id) }
  end

  def provider(id, rd_api_key:)
    provider_entries(rd_api_key: rd_api_key).find { |entry| entry.fetch(:id) == id.to_s }
  end

  # All base URLs that resolve URLs may originate from — used by
  # ContentStreamingService for allowed_resolve_origins.
  def resolve_base_urls
    setting = ENV.fetch("STREAM_PROVIDER", "torrentio").to_s.downcase
    urls = []

    case setting
    when "comet", "auto"
      urls << CometService.comet_url if CometService.comet_url.present?
      urls << TorrentioService::TORRENTIO_URL
      urls << "https://torrentio.strem.fun"
    else
      urls << TorrentioService::TORRENTIO_URL
      urls << "https://torrentio.strem.fun"
    end

    urls.uniq
  end
end
