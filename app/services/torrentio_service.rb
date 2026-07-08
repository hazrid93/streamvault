# frozen_string_literal: true

class TorrentioService
  include StreamCompatibility
  include Cacheable
  TORRENTIO_URL = ENV.fetch("TORRENTIO_API_BASE_URL", "https://torrentio.strem.fun")
  CINEMETA_URL = "https://v3-cinemeta.strem.io"
  QUALITY_SORT = { "4K" => 0, "1080p" => 1, "720p" => 2, "480p" => 3, "Unknown" => 4 }.freeze

  # Cinemeta catalog ids double as sort modes: "top" = popular,
  # "year" = new releases, "imdbRating" = top rated.
  CATALOGS = {
    "top" => "Popular",
    "year" => "New Releases",
    "imdbRating" => "Top Rated"
  }.freeze

  # Genres supported by the cinemeta catalog (per the addon manifest).
  MOVIE_GENRES = %w[Action Adventure Animation Biography Comedy Crime
                    Documentary Drama Family Fantasy History Horror Mystery
                    Romance Sci-Fi Sport Thriller War Western].freeze
  SERIES_GENRES = %w[Action Adventure Animation Biography Comedy Crime
                     Documentary Drama Family Fantasy History Horror Mystery
                     Romance Sci-Fi Sport Thriller War Western
                     Reality-TV Talk-Show Game-Show].freeze

  # How many items a single cinemeta catalog page returns.
  CATALOG_PAGE_SIZE = 50

  LANGUAGE_PATTERNS = {
    "ENG" => /\b(ENG|ENGLISH|EN)\b/i,
    "FRENCH" => /\b(FRENCH|FR|VFF|VFQ|TRUEFRENCH)\b/i,
    "GERMAN" => /\b(GERMAN|GER|DE)\b/i,
    "SPANISH" => /\b(SPANISH|SPA|ES|CASTELLANO)\b/i,
    "ITALIAN" => /\b(ITALIAN|ITA|IT)\b/i,
    "JAPANESE" => /\b(JAPANESE|JAP|JA)\b/i,
    "KOREAN" => /\b(KOREAN|KOR|KO)\b/i,
    "CHINESE" => /\b(CHINESE|CHI|ZH)\b/i,
    "HINDI" => /\b(HINDI|HIN|HI)\b/i,
    "ARABIC" => /\b(ARABIC|ARA|AR)\b/i,
    "PORTUGUESE" => /\b(PORTUGUESE|POR|PT|PTBR|BRAZILIAN)\b/i,
    "RUSSIAN" => /\b(RUSSIAN|RUS|RU)\b/i,
    "DUTCH" => /\b(DUTCH|DUT|NL|NLD)\b/i,
    "POLISH" => /\b(POLISH|POL|PL)\b/i,
    "TURKISH" => /\b(TURKISH|TUR|TR)\b/i,
    "SWEDISH" => /\b(SWEDISH|SWE|SV)\b/i
  }.freeze

  def initialize(rd_api_key: nil)
    @rd_api_key = rd_api_key

    torrentio_proxy = ENV["TORRENTIO_PROXY"]
    # Cinemeta has its own proxy config: it redirects to
    # cinemeta-catalogs.strem.io, which the torrentio Tinyproxy whitelist
    # doesn't include (403 "Filtered").  Default to a direct connection
    # — cinemeta is not behind the same Cloudflare WAF as torrentio.
    cinemeta_proxy = ENV["CINEMETA_PROXY"]

    @torrentio = Faraday.new(url: TORRENTIO_URL) do |f|
      f.request :json
      f.response :json
      f.response :follow_redirects
      f.adapter Faraday.default_adapter
      f.options.timeout = 15
      f.options.open_timeout = 5
      f.proxy = torrentio_proxy if torrentio_proxy.present?
    end

    @cinemeta = Faraday.new(url: CINEMETA_URL) do |f|
      f.response :json
      f.response :follow_redirects
      f.adapter Faraday.default_adapter
      f.options.timeout = 10
      f.options.open_timeout = 5
      f.proxy = cinemeta_proxy if cinemeta_proxy.present?
    end
  end

  def search(query)
    return ServiceResult.failure("Query cannot be blank") if query.blank?

    # Search results change rarely for a given query — cache in the DB
    # with stale-while-revalidate so repeat searches are instant.
    cache_key = "cinemeta:search:#{query.downcase}"
    results = cached_fetch(cache_key, ttl: SEARCH_CACHE_TTL) do
      fetch_search_uncached(query)
    end

    ServiceResult.success(results || [])
  rescue StandardError => e
    Rails.logger.error("TorrentioService#search error: #{e.message}")
    ServiceResult.failure("Search failed")
  end

  def fetch_search_uncached(query)
    encoded = URI.encode_www_form_component(query)
    results = []

    %w[movie series].each do |type|
      response = @cinemeta.get("catalog/#{type}/top/search=#{encoded}.json")
      next unless response.success? && response.body.is_a?(Hash)
      (response.body["metas"] || []).each { |meta| results << normalize_cinemeta(meta, type) }
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed
    end

    results
  end

  def streams(imdb_id, type, season: nil, episode: nil, title: nil, preferred_languages: nil, default_language: nil)
    return ServiceResult.failure("IMDB ID is required") if imdb_id.blank?

    # Stream listings depend on the user's RealDebrid account (Torrentio
    # embeds the RD key in the path and checks RD instant availability
    # per key), so cache per-RD-key-hash.  Stale-while-revalidate.
    cache_key = "torrentio:streams:#{rd_key_hash}/#{imdb_id}/#{type}/#{season}/#{episode}"
    parsed = cached_fetch(cache_key, ttl: STREAMS_CACHE_TTL) do
      fetch_streams_uncached(imdb_id, type, season: season, episode: episode)
    end

    return ServiceResult.success([]) if parsed.nil?

    language_priority = normalize_language_priority(default_language, preferred_languages)
    result = parsed
    result = filter_by_preferred_languages(result, language_priority, default_language: default_language) if language_priority.present?
    result = sort_streams(result, language_priority: language_priority)
    ServiceResult.success(result)
  end

  # Fetch + parse raw streams from Torrentio (no language filtering).
  # Returns the parsed array, [] for a 404, or nil on error (not cached).
  def fetch_streams_uncached(imdb_id, type, season: nil, episode: nil)
    path = build_stream_path(imdb_id, type, season: season, episode: episode)
    response = @torrentio.get(path)

    if response.success? && response.body.is_a?(Hash) && response.body["streams"]
      parse_streams(response.body["streams"])
    elsif response.status == 404
      []
    else
      Rails.logger.error("[TorrentioService] streams request failed: HTTP #{response.status} for #{redact_path(path)}")
      nil
    end
  rescue Faraday::TimeoutError
    Rails.logger.error("[TorrentioService] streams request timed out for #{redact_path(path)}")
    nil
  rescue Faraday::ConnectionFailed => e
    Rails.logger.error("[TorrentioService] streams connection failed: #{e.message}")
    nil
  rescue StandardError => e
    Rails.logger.error("[TorrentioService] streams error: #{e.message}")
    nil
  end

  METADATA_CACHE_TTL = 1.day
  CATALOG_CACHE_TTL = 1.day
  SEARCH_CACHE_TTL = 6.hours
  STREAMS_CACHE_TTL = 1.hour
  OMDB_CACHE_TTL = 7.days

  def metadata(imdb_id, type)
    return ServiceResult.failure("IMDB ID is required") if imdb_id.blank?

    # Title metadata changes rarely — cache it in the DB (survives
    # restarts, shared across users) with stale-while-revalidate: a
    # stale hit is served instantly and refreshed in the background.
    cache_key = "cinemeta:meta:#{type}/#{imdb_id}"
    data = cached_fetch(cache_key, ttl: METADATA_CACHE_TTL) do
      fetch_metadata_uncached(imdb_id, type)
    end

    return ServiceResult.failure("Metadata not found") if data.nil?
    ServiceResult.success(data)
  end

  def fetch_metadata_uncached(imdb_id, type)
    cinemeta_type = type.to_s == "show" ? "series" : type.to_s
    response = @cinemeta.get("meta/#{cinemeta_type}/#{imdb_id}.json")

    if response.success? && response.body.is_a?(Hash) && response.body["meta"]
      result = normalize_cinemeta_meta(response.body["meta"], type)
      result.merge!(fetch_omdb_ratings(imdb_id))
      result
    else
      nil
    end
  rescue Faraday::TimeoutError
    Rails.logger.error("[TorrentioService] metadata request timed out for #{imdb_id}")
    nil
  rescue Faraday::ConnectionFailed => e
    Rails.logger.error("[TorrentioService] metadata connection failed: #{e.message}")
    nil
  rescue StandardError => e
    Rails.logger.error("TorrentioService#metadata error: #{e.message}")
    nil
  end
  def popular(type, limit: 20)
    catalog(type, "top", limit: limit)
  end

  def trending(type, limit: 20)
    catalog(type, "year", genre: Date.today.year.to_s, limit: limit)
  end

  def featured(type, limit: 20)
    catalog(type, "imdbRating", limit: limit)
  end

  # Fetch a cinemeta catalog page.  +genre+ and +skip+ are passed in the
  # URL *path* (e.g. catalog/movie/top/genre=Action&skip=100.json) because
  # cinemeta ignores them as query parameters — using ?genre= silently
  # returns the unfiltered catalog.
  def catalog(type, catalog_id, genre: nil, skip: nil, limit: 20)
    cinemeta_type = type.to_s == "show" ? "series" : type.to_s
    extras = []
    extras << "genre=#{CGI.escape(genre)}" if genre.present?
    extras << "skip=#{skip.to_i}" if skip.present? && skip.to_i.positive?
    path = if extras.any?
      "catalog/#{cinemeta_type}/#{catalog_id}/#{extras.join('&')}.json"
    else
      "catalog/#{cinemeta_type}/#{catalog_id}.json"
    end

    # DB-backed stale-while-revalidate: a stale catalog page is served
    # instantly and refreshed in the background.  The advisory lock
    # coalesces concurrent refreshes onto a single HTTP call.
    cache_key = "cinemeta:catalog/#{cinemeta_type}/#{catalog_id}/#{genre}/#{skip}/#{limit}"
    result = cached_fetch(cache_key, ttl: CATALOG_CACHE_TTL) do
      fetch_catalog_uncached(path, type, limit)
    end

    ServiceResult.success(result || [])
  rescue StandardError => e
    Rails.logger.error("TorrentioService#catalog error: #{e.message}")
    ServiceResult.success([])
  end

  def fetch_catalog_uncached(path, type, limit)
    response = @cinemeta.get(path)
    if response.success? && response.body.is_a?(Hash)
      metas = response.body["metas"] || []
      metas = metas.first(limit) if limit && limit.positive?
      metas.map { |m| normalize_cinemeta(m, type.to_s) }
    else
      []
    end
  rescue StandardError => e
    Rails.logger.error("TorrentioService#fetch_catalog_uncached error: #{e.message}")
    []
  end

  # Genres available for a given content type.
  def self.genres_for(type)
    type.to_s == "show" ? SERIES_GENRES : MOVIE_GENRES
  end

  private

  def filter_by_preferred_languages(streams, preferred_languages, default_language: nil)
    return streams if preferred_languages.blank?
    langs = normalize_language_list(preferred_languages)

    streams.select do |s|
      # Streams with no detectable language are almost always English —
      # it's the implicit/unmarked language of torrent titles.  Include
      # them if English is in the preferred list; otherwise filter them
      # out (user wants only non-English content).
      (s[:languages] & langs).any? || (s[:languages].empty? && langs.include?("ENG"))
    end
  end

  # Sort: user language preference first, then compatibility (prefer streams
  # that play directly or via stream-copy over heavy-transcode ones), RD+,
  # quality, and size.
  def sort_streams(streams, language_priority: [])
    streams_with_scores = streams.map do |stream|
      stream.merge(language_score: stream_language_score(stream, language_priority))
    end

    streams_with_scores.sort_by do |s|
      language_score = s[:language_score]
      compatibility_score = -(s[:compatibility_score] || 0)
      rd_score = s[:rd_plus] ? 0 : 1
      quality_score = QUALITY_SORT[s[:quality]] || 4
      size_bytes = s[:raw_size].is_a?(Numeric) ? s[:raw_size] : 0
      [ language_score, compatibility_score, rd_score, quality_score, -size_bytes ]
    end
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

  # Stable, non-reversible hash of the RD key for per-account cache
  # isolation (avoids leaking the raw key in cache keys/logs).
  def rd_key_hash
    return "none" if @rd_api_key.blank?
    Digest::SHA256.hexdigest(@rd_api_key)[0, 16]
  end

  def build_stream_path(imdb_id, type, season: nil, episode: nil)
    base = @rd_api_key.present? ? "/realdebrid=#{@rd_api_key}" : ""

    episode_path = if type.to_s.in?(%w[show series]) && season && episode
      "series/#{imdb_id}:#{season}:#{episode}"
    else
      "movie/#{imdb_id}"
    end

    "#{base}/stream/#{episode_path}.json"
  end

  # Redact the RealDebrid API key from paths before logging so the
  # plaintext key never enters the production log.  The key is embedded
  # in build_stream_path as "/realdebrid=<KEY>/stream/...".
  def redact_path(path)
    return path if @rd_api_key.blank?
    path.to_s.gsub(@rd_api_key, "[REDACTED]")
  end

  def parse_streams(raw_streams)
    raw_streams.map do |s|
      title_text = s["title"].to_s
      filename = s.dig("behaviorHints", "filename").to_s
      size_bytes = parse_size_bytes(title_text)
      video_codec = detect_video_codec(title_text)
      audio_codec = detect_audio_codec(title_text)
      container = detect_container(filename.presence || title_text)
      {
        title: s["title"],
        info_hash: s["infoHash"],
        file_idx: s["fileIdx"],
        name: s["name"],
        quality: extract_quality(s["title"] || s["name"]),
        seeders: extract_seeders(s),
        size: size_bytes ? format_size(size_bytes) : "Unknown",
        raw_size: size_bytes || 0,
        rd_plus: s["sources"].is_a?(Array) && s["sources"].any?,
        filename: filename,
        resolve_url: rewrite_resolve_url(s["url"]),
        languages: extract_languages(title_text),
        video_codec: video_codec,
        audio_codec: audio_codec,
        container: container,
        compatibility_score: compatibility_score(video_codec: video_codec, audio_codec: audio_codec, container: container)
      }
    end
  end

  # Rewrite resolve URLs to use the configured TORRENTIO_API_BASE_URL
  # instead of the default torrentio.strem.fun host.  When a custom base
  # URL is set (e.g. a Cloudflare Worker proxy), resolve URLs in the API
  # response still point to torrentio.strem.fun — we rewrite them so the
  # ContentStreamingService follow request goes through the proxy too.
  def rewrite_resolve_url(url)
    return url if url.blank?
    return url if TORRENTIO_URL == "https://torrentio.strem.fun"
    url.sub("https://torrentio.strem.fun", TORRENTIO_URL)
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

  def extract_seeders(stream)
    if stream["seeders"]
      stream["seeders"]
    elsif stream["title"] && stream["title"] =~ /👤\s*(\d+)/
      $1.to_i
    else
      0
    end
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

  def normalize_cinemeta(meta, type)
    {
      imdb_id: meta["imdb_id"] || meta["id"],
      title: meta["name"],
      year: meta["releaseInfo"] || meta["year"],
      type: type == "series" ? "show" : type,
      poster_url: meta["poster"],
      imdb_rating: meta["imdbRating"],
      genre: meta["genres"]&.join(", ")
    }
  end

  def normalize_cinemeta_meta(meta, type)
    {
      imdb_id: meta["imdb_id"] || meta["id"],
      title: meta["name"],
      year: meta["year"] || meta["releaseInfo"],
      type: type,
      poster_url: meta["poster"],
      background_url: meta["background"],
      plot: meta["description"],
      genre: meta["genres"]&.join(", "),
      director: meta["director"]&.join(", "),
      actors: meta["cast"]&.join(", "),
      rated: meta["certification"],
      imdb_rating: meta["imdbRating"],
      runtime: meta["runtime"],
      runtime_seconds: parse_runtime_seconds(meta["runtime"]),
      total_seasons: extract_total_seasons(meta),
      episodes: extract_episodes(meta)
    }
  end

  def fetch_omdb_ratings(imdb_id)
    api_key = ENV.fetch("OMDB_API_KEY", "")
    return {} if api_key.blank? || api_key == "your_omdb_api_key_here"

    # OMDb ratings are effectively static — cache in the DB for a week.
    cache_key = "omdb:ratings/#{imdb_id}"
    cached_fetch(cache_key, ttl: OMDB_CACHE_TTL) do
      fetch_omdb_ratings_uncached(imdb_id, api_key)
    end || {}
  end

  def fetch_omdb_ratings_uncached(imdb_id, api_key)
    response = omdb_connection.get("", { i: imdb_id, apikey: api_key, tomatoes: "true" })
    data = response.body
    return nil unless data.is_a?(Hash) && data["Response"] == "True"

    rt_rating = nil
    if data["Ratings"].is_a?(Array)
      rt = data["Ratings"].find { |r| r["Source"] == "Rotten Tomatoes" }
      rt_rating = rt["Value"] if rt
    end

    {
      rated: data["Rated"] != "N/A" ? data["Rated"] : nil,
      rt_rating: rt_rating,
      metascore: data["Metascore"] != "N/A" ? data["Metascore"] : nil
    }
  rescue Faraday::TimeoutError, Faraday::ConnectionFailed, StandardError
    nil
  end

  # Memoize the OMDb connection so repeated metadata calls reuse it
  # instead of building a new Faraday object per call.
  def omdb_connection
    @omdb_connection ||= Faraday.new(url: "https://www.omdbapi.com") do |f|
      f.response :json
      f.adapter Faraday.default_adapter
      f.options.timeout = 5
      f.options.open_timeout = 3
    end
  end

  def extract_total_seasons(meta)
    videos = meta["videos"]
    return nil unless videos.is_a?(Array)
    videos.map { |v| v["season"] }.compact.max
  end

  def extract_episodes(meta)
    videos = meta["videos"]
    return [] unless videos.is_a?(Array)

    videos.select { |v| v["episode"] }.map do |v|
      {
        season: v["season"],
        episode: v["episode"],
        title: v["name"].presence || "Episode #{v["episode"]}",
        released: v["released"]&.to_date&.to_s,
        imdb_id: v["id"],
        overview: v["overview"],
        runtime: v["runtime"],
        runtime_seconds: parse_runtime_seconds(v["runtime"])
      }
    end
  end

  def parse_runtime_seconds(runtime)
    value = runtime.to_s.strip
    return nil if value.blank?

    if (iso = value.match(/\APT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?\z/i))
      hours = iso[1].to_i
      minutes = iso[2].to_i
      seconds = iso[3].to_i
      total = (hours * 3600) + (minutes * 60) + seconds
      return total.positive? ? total : nil
    end

    hours = value[/(\d+(?:\.\d+)?)\s*(?:h|hr|hrs|hour|hours)\b/i, 1].to_f
    minutes = value[/(\d+(?:\.\d+)?)\s*(?:m|min|mins|minute|minutes)\b/i, 1].to_f

    if hours.positive? || minutes.positive?
      total = ((hours * 3600) + (minutes * 60)).round
      return total.positive? ? total : nil
    end

    numeric_minutes = value[/\A(\d+(?:\.\d+)?)\z/, 1]&.to_f
    return (numeric_minutes * 60).round if numeric_minutes&.positive?

    nil
  end
end
