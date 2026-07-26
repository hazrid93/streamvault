# frozen_string_literal: true

# Uses the official OpenSubtitles v3 Stremio add-on. Its download relay
# returns UTF-8 subtitle files without consuming StreamVault's limited SubDL
# daily download quota.
class OpenSubtitlesStremioProvider
  API_BASE_URL = ENV.fetch("OPENSUBTITLES_STREMIO_URL", "https://opensubtitles-v3.strem.io")
  MAX_RESULTS = 12
  MAX_DOWNLOAD_BYTES = 5.megabytes
  SEARCH_CACHE_TTL = 30.minutes
  DOWNLOAD_HOST_PATTERN = /\Asubs\d+\.strem\.io\z/i
  DOWNLOAD_PATH_PREFIX = "/en/download/"

  LANGUAGE_CODES = {
    "ENG" => %w[eng],
    "FRENCH" => %w[fre fra],
    "GERMAN" => %w[ger deu],
    "SPANISH" => %w[spa],
    "ITALIAN" => %w[ita],
    "JAPANESE" => %w[jpn],
    "KOREAN" => %w[kor],
    "CHINESE" => %w[chi zho],
    "HINDI" => %w[hin],
    "ARABIC" => %w[ara],
    "PORTUGUESE" => %w[por pob],
    "RUSSIAN" => %w[rus],
    "DUTCH" => %w[dut nld],
    "POLISH" => %w[pol],
    "TURKISH" => %w[tur],
    "SWEDISH" => %w[swe]
  }.freeze

  def initialize(search_connection: nil, download_connection: nil)
    @search_connection = search_connection || build_connection(API_BASE_URL, json: true)
    @download_connection = download_connection || build_connection(nil, json: false)
  end

  def search(imdb_id:, type:, season: nil, episode: nil, title: nil, filename: nil, preferred_languages: [], default_language: nil)
    imdb = imdb_id.to_s
    return [] unless imdb.match?(/\Att\d+\z/)

    media_type, media_id = media_endpoint(imdb, type, season, episode)
    cache_key = "opensubtitles_stremio/search/#{media_type}/#{media_id}/#{language_priority(preferred_languages, default_language).join(',')}"
    Rails.cache.fetch(cache_key, expires_in: SEARCH_CACHE_TTL) do
      response = @search_connection.get("subtitles/#{media_type}/#{media_id}.json")
      next [] unless response.success? && response.body.is_a?(Hash)

      normalize_tracks(response.body, preferred_languages, default_language)
    end
  rescue Faraday::TimeoutError, Faraday::ConnectionFailed => error
    Rails.logger.info("[OpenSubtitles] search unavailable: #{error.class.name}")
    []
  rescue StandardError => error
    Rails.logger.error("[OpenSubtitles] search failed: #{error.class.name}")
    []
  end

  def download(url)
    return ServiceResult.failure("Invalid OpenSubtitles download URL") unless valid_download_url?(url)

    response = @download_connection.get(url.to_s)
    return ServiceResult.failure("OpenSubtitles download failed", response.status) unless response.success?

    body = response.body.to_s
    return ServiceResult.failure("OpenSubtitles file is too large") if body.bytesize > MAX_DOWNLOAD_BYTES

    ServiceResult.success(body)
  rescue Faraday::TimeoutError, Faraday::ConnectionFailed
    ServiceResult.failure("OpenSubtitles download timed out")
  rescue StandardError => error
    Rails.logger.error("[OpenSubtitles] download failed: #{error.class.name}")
    ServiceResult.failure("OpenSubtitles download failed")
  end

  private

  def media_endpoint(imdb_id, type, season, episode)
    if type.to_s.in?(%w[show series tv]) && season.to_i.positive? && episode.to_i.positive?
      [ "series", "#{imdb_id}:#{season.to_i}:#{episode.to_i}" ]
    else
      [ "movie", imdb_id ]
    end
  end

  def normalize_tracks(body, preferred_languages, default_language)
    priority = language_priority(preferred_languages, default_language)
    tracks = Array(body["subtitles"]).filter_map do |subtitle|
      url = subtitle["url"].to_s
      next unless valid_download_url?(url)

      language = language_from_code(subtitle["lang"])
      next unless language

      {
        index: ExternalSubtitleService.stream_id("opensubtitles", url),
        position: nil,
        language: language,
        language_label: language_label(language),
        title: "OpenSubtitles",
        codec: "srt",
        default: false,
        text_supported: true,
        forced: false,
        hearing_impaired: subtitle["m"].to_s == "h",
        commentary: false,
        partial: false,
        quality: "full",
        quality_score: 0,
        external: true,
        source: "opensubtitles",
        label: "#{language_label(language)} · OpenSubtitles"
      }
    end

    tracks
      .sort_by { |track| [ priority.index(track[:language]) || priority.length, track[:language].to_s, track[:index].to_s ] }
      .uniq { |track| [ track[:language], track[:index] ] }
      .first(MAX_RESULTS)
  end

  def language_priority(preferred_languages, default_language)
    ([ default_language ] + Array(preferred_languages)).map(&:to_s).map(&:upcase).select { |language| LANGUAGE_CODES.key?(language) }.uniq.presence || [ "ENG" ]
  end

  def language_from_code(code)
    normalized = code.to_s.downcase
    LANGUAGE_CODES.find { |_, codes| codes.include?(normalized) }&.first
  end

  def language_label(language)
    User::STREAM_LANGUAGE_OPTIONS[language] || language
  end

  def valid_download_url?(url)
    uri = URI.parse(url.to_s)
    uri.is_a?(URI::HTTPS) &&
      uri.userinfo.nil? &&
      uri.port == 443 &&
      uri.host.to_s.match?(DOWNLOAD_HOST_PATTERN) &&
      uri.path.start_with?(DOWNLOAD_PATH_PREFIX)
  rescue URI::InvalidURIError
    false
  end

  def build_connection(url, json:)
    Faraday.new(url: url) do |faraday|
      faraday.response :json if json
      faraday.adapter Faraday.default_adapter
      faraday.options.timeout = 12
      faraday.options.open_timeout = 5
    end
  end
end
