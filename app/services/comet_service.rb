# frozen_string_literal: true

require "base64"
require "json"

# Stream provider for self-hosted Comet (https://github.com/g0ldyy/comet).
#
# Comet speaks the standard Stremio addon protocol — /stream/{type}/{id}.json
# returns { "streams": [...] } — but the RealDebrid API key and user
# preferences are encoded in a base64 config path segment instead of the
# /realdebrid={key}/ prefix that Torrentio uses.
#
# Comet's config is a JSON object base64-encoded for the URL:
#   {"debridService":"realdebrid","debridApiKey":"<key>","...":"..."}
# The stream path becomes:
#   /{b64config}/stream/{type}/{id}.json
#
# When no config is needed (no RD key, default options), Comet serves at:
#   /stream/{type}/{id}.json
#
# Resolve URLs in Comet's stream response point to the Comet host's
# /{b64config}/playback/... endpoint, which 302-redirects to the
# RealDebrid direct download URL — same follow-redirect flow as Torrentio.
class CometService
  include StreamCompatibility
  include Cacheable
  LANGUAGE_PATTERNS = TorrentioService::LANGUAGE_PATTERNS
  STREAMS_CACHE_TTL = 1.hour
  STREAM_CACHE_VERSION = 2

  def self.comet_url
    ENV.fetch("COMET_URL", "")
  end

  def self.comet_proxy
    ENV.fetch("COMET_PROXY", "")
  end

  def initialize(rd_api_key: nil)
    @rd_api_key = rd_api_key
    @comet = Faraday.new(url: self.class.comet_url) do |f|
      f.request :json
      f.response :json
      f.response :follow_redirects
      f.adapter Faraday.default_adapter
      f.options.timeout = 30
      f.options.open_timeout = 5
      f.proxy = self.class.comet_proxy if self.class.comet_proxy.present?
    end
  end

  def streams(imdb_id, type, season: nil, episode: nil, title: nil, preferred_languages: nil, default_language: nil)
    return ServiceResult.failure("IMDB ID is required") if imdb_id.blank?
    return ServiceResult.failure("Comet URL not configured") if self.class.comet_url.blank?

    # Stream listings depend on the user's RealDebrid account (Comet checks
    # RD instant availability per key, and resolve URLs embed the key), so
    # cache per-RD-key-hash.  Stale-while-revalidate: a stale listing is
    # served instantly and refreshed in the background.
    cache_key = "comet:streams:v#{STREAM_CACHE_VERSION}:#{rd_key_hash}/#{imdb_id}/#{type}/#{season}/#{episode}"
    parsed = cached_fetch(cache_key, ttl: STREAMS_CACHE_TTL) do
      fetch_streams_uncached(imdb_id, type, season: season, episode: episode)
    end

    return ServiceResult.success([]) if parsed.nil?

    # Apply per-request language filtering + sorting on the cached (or
    # freshly fetched) parsed streams — cheap, no upstream call.
    language_priority = normalize_language_priority(default_language, preferred_languages)
    result = parsed
    result = filter_by_preferred_languages(result, language_priority) if language_priority.present?
    result = sort_streams(result, language_priority: language_priority)
    ServiceResult.success(result)
  end

  # Fetch + parse raw streams from Comet (no language filtering).  Returns
  # the parsed array, or nil on error (nil is intentionally not cached so
  # a transient Comet outage doesn't stick).  An empty 404 returns []
  # (cacheable — avoids re-hammering Comet for content with no streams).
  def fetch_streams_uncached(imdb_id, type, season: nil, episode: nil)
    path = build_stream_path(imdb_id, type, season: season, episode: episode)
    response = @comet.get(path)

    if response.success? && response.body.is_a?(Hash) && response.body["streams"]
      parse_streams(response.body["streams"])
    elsif response.status == 404
      []
    else
      Rails.logger.error("[CometService] streams request failed: HTTP #{response.status} for #{path}")
      nil
    end
  rescue Faraday::TimeoutError
    Rails.logger.error("[CometService] streams request timed out for #{path}")
    nil
  rescue Faraday::ConnectionFailed => e
    Rails.logger.error("[CometService] streams connection failed: #{e.message}")
    nil
  rescue StandardError => e
    Rails.logger.error("[CometService] streams error: #{e.message}")
    nil
  end

  # The base URL for resolve-URL origin validation.  Comet's playback
  # endpoints live on the same host as the stream listing.
  def self.resolve_base_url
    comet_url
  end

  private

  # Stable, non-reversible hash of the RD key for cache isolation.  Keying
  # by the hash (not the raw key) avoids leaking the API key in cache keys
  # or logs, while still giving each account its own cache namespace.
  def rd_key_hash
    return "none" if @rd_api_key.blank?
    Digest::SHA256.hexdigest(@rd_api_key)[0, 16]
  end

  def build_stream_path(imdb_id, type, season: nil, episode: nil)
    config = build_config
    prefix = config ? "/#{config}" : ""

    episode_path = if type.to_s.in?(%w[show series]) && season && episode
      "series/#{imdb_id}:#{season}:#{episode}"
    else
      "movie/#{imdb_id}"
    end

    "#{prefix}/stream/#{episode_path}.json"
  end

  # Build the base64-encoded config path segment.  When the RD key is
  # absent, return nil so Comet serves at the default (no-config) path.
  def build_config
    return nil if @rd_api_key.blank?

    config = {
      "debridService" => "realdebrid",
      "debridApiKey" => @rd_api_key
    }
    # NOTE: Comet requires standard (padded) base64.  Using `padding: false`
    # produces unpadded base64, which Comet's config parser fails to decode —
    # it silently treats the request as having no debrid config and returns a
    # single placeholder stream instead of real results.
    Base64.urlsafe_encode64(JSON.generate(config))
  end

  # Parse Comet stream objects into the same normalized hash shape that
  # TorrentioService produces, so ContentStreamingService can consume
  # streams from either provider interchangeably.
  # Comet's Stremio stream objects carry the real metadata in `description`
  # and `behaviorHints`, NOT in top-level `title`/`infoHash`/`sources` (those
  # are Torrentio's shape).  Comet returns:
  #   name        => "[RD⚡] Comet 2160p"  (identical across same-resolution
  #                                        streams — useless as a label)
  #   description => "📄 <release>.mkv\n🎞 ...\n⭐ ...\n💾 50.4 GB 🔎 DMM"
  #   behaviorHints.filename  => the actual release name
  #   behaviorHints.videoSize  => file size in bytes
  #   behaviorHints.bingeGroup => "comet|realdebrid|<sha1_info_hash>"
  def parse_streams(raw_streams)
    raw_streams.map do |s|
      description = s["description"].to_s
      behavior_hints = s["behaviorHints"] || {}
      filename = behavior_hints["filename"].to_s

      binge_group = behavior_hints["bingeGroup"].to_s
      info_hash = binge_group.split("|").last.presence || s["infoHash"]

      title_text = filename.presence || s["name"].to_s
      size_bytes = behavior_hints["videoSize"] || parse_size_bytes(description)
      cached = s["name"].to_s.include?("⚡")

      # Parse codec/container from the release name and filename.
      # Comet's title_text is the actual release filename; description
      # may also contain the container extension for codec hints.
      video_codec = detect_video_codec(title_text)
      audio_codec = detect_audio_codec(title_text)
      container = detect_container(filename.presence || description)

      {
        title: title_text,
        info_hash: info_hash,
        file_idx: s["fileIdx"],
        name: s["name"],
        quality: extract_quality(s["name"] || title_text),
        seeders: extract_seeders(s, description),
        size: size_bytes ? format_size(size_bytes) : "Unknown",
        raw_size: size_bytes || 0,
        rd_plus: cached,
        filename: filename,
        resolve_url: s["url"].to_s,
        languages: extract_languages(description),
        video_codec: video_codec,
        audio_codec: audio_codec,
        container: container,
        compatibility_score: compatibility_score(video_codec: video_codec, audio_codec: audio_codec, container: container)
      }
    end
  end

  def filter_by_preferred_languages(streams, preferred_languages, default_language: nil)
    return streams if preferred_languages.blank?
    langs = normalize_language_list(preferred_languages)

    streams.select do |s|
      (s[:languages] & langs).any? || (s[:languages].empty? && langs.include?("ENG"))
    end
  end

  def sort_streams(streams, language_priority: [])
    streams_with_scores = streams.map do |stream|
      stream.merge(language_score: stream_language_score(stream, language_priority))
    end

    StreamOrdering.sort(streams_with_scores)
  end

  def stream_language_score(stream, language_priority)
    return 0 if language_priority.blank?

    stream_languages = Array(stream[:languages]).map(&:to_s).map(&:upcase)
    # Unmarked streams are assumed English — score them as ENG.
    stream_languages = [ "ENG" ] if stream_languages.empty?
    matching_indexes = stream_languages.filter_map { |language| language_priority.index(language) }
    matching_indexes.min || language_priority.length
  end

  def normalize_language_priority(default_language, preferred_languages)
    normalize_language_list([ default_language ] + Array(preferred_languages))
  end

  def normalize_language_list(languages)
    Array(languages)
      .flatten
      .map(&:to_s)
      .map(&:upcase)
      .select { |language| LANGUAGE_PATTERNS.key?(language) }
      .uniq
  end

  def extract_languages(title)
    return [] if title.blank?
    langs = LANGUAGE_PATTERNS.select { |_, pattern| title.match?(pattern) }.keys
    langs = LANGUAGE_PATTERNS.keys if title.match?(/\bMULTi|MULTIPLE|MULTI\b/i)
    langs
  end

  def parse_size_bytes(title)
    match = title.match(/💾\s*([\d.]+)\s*(GB|MB|KB)/i)
    return nil unless match
    value = match[1].to_f
    case match[2].upcase
    when "GB" then (value * 1_073_741_824).to_i
    when "MB" then (value * 1_048_576).to_i
    when "KB" then (value * 1024).to_i
    end
  end

  def extract_quality(title)
    return "Unknown" unless title
    case title
    when /2160p|4K/i then "4K"
    when /1080p/i then "1080p"
    when /720p/i then "720p"
    when /480p/i then "480p"
    else "Unknown"
    end
  end

  def extract_seeders(stream, description = nil)
    value = stream["seeders"]
    return value.to_i if value.is_a?(Numeric) || value.to_s.match?(/\A\d+\z/)

    match = [ stream["title"], description ].compact.join(" ").match(/👤\s*(\d+)/)
    match ? match[1].to_i : nil
  end

  def format_size(bytes)
    return "Unknown" unless bytes.is_a?(Numeric)
    if bytes >= 1_073_741_824
      "#{(bytes / 1_073_741_824.0).round(1)} GB"
    elsif bytes >= 1_048_576
      "#{(bytes / 1_048_576.0).round(1)} MB"
    else
      "#{(bytes / 1024.0).round(1)} KB"
    end
  end
end
