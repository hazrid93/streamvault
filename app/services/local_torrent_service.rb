# frozen_string_literal: true

require "base64"
require "cgi"
require "open3"
require "zlib"

# Internal client for the TorrServer sidecar. TorrServer is never exposed on a
# host port: Rails validates the selected info hash/file and proxies the stream
# through the existing authenticated direct/remux/transcode pipeline.
class LocalTorrentService
  CACHE_BYTES = ENV.fetch("LOCAL_TORRENT_CACHE_BYTES", 10.gigabytes.to_i).to_i.clamp(512.megabytes, 50.gigabytes)
  MIN_FREE_BYTES = ENV.fetch("LOCAL_TORRENT_MIN_FREE_BYTES", 5.gigabytes.to_i).to_i.clamp(1.gigabyte, 100.gigabytes)
  DISCONNECT_TIMEOUT = ENV.fetch("LOCAL_TORRENT_DISCONNECT_TIMEOUT", 60).to_i.clamp(30, 21_600)
  UPLOAD_LIMIT_KBPS = ENV.fetch("LOCAL_TORRENT_UPLOAD_LIMIT_KBPS", 512).to_i.clamp(0, 100_000)
  CACHE_PATH = ENV.fetch("LOCAL_TORRENT_CACHE_PATH", "/rails/storage/local_torrents")
  VIDEO_EXTENSIONS = %w[.mp4 .mkv .webm .avi .mov .m4v .ts .m2ts .mpg .mpeg].freeze
  INFO_HASH_FORMAT = /\A[0-9a-f]{40}\z/i
  START_LOCK_ID = Zlib.crc32("streamvault-local-torrent-start")
  START_MUTEX = Mutex.new
  METADATA_TIMEOUT = 30.seconds

  class << self
    def enabled?
      ENV.fetch("LOCAL_TORRENT_ENABLED", "false") == "true" && base_url.present?
    end

    def base_url
      ENV.fetch("TORRSERVER_URL", "http://torrserver:8090").presence
    end

    def internal_host
      URI.parse(base_url).host if base_url
    rescue URI::InvalidURIError
      nil
    end
  end

  def initialize
    @connection = Faraday.new(url: self.class.base_url) do |faraday|
      faraday.request :json
      faraday.response :json
      faraday.adapter Faraday.default_adapter
      faraday.options.open_timeout = 3
      faraday.options.timeout = 15
    end
    if ENV["TORRSERVER_USERNAME"].present?
      credentials = Base64.strict_encode64("#{ENV.fetch('TORRSERVER_USERNAME')}:#{ENV.fetch('TORRSERVER_PASSWORD', '')}")
      @connection.headers["Authorization"] = "Basic #{credentials}"
    end
  end

  def start(info_hash:, file_idx: nil, filename: nil, title: nil, poster_url: nil)
    return ServiceResult.failure("Local torrent playback is disabled") unless self.class.enabled?

    hash = normalize_hash(info_hash)
    return ServiceResult.failure("This stream does not include a valid torrent info hash") unless hash
    return ServiceResult.failure("Not enough free disk space for local playback") unless enough_disk_space?

    with_start_lock do
      ensure_settings!
      existing = list_torrents
      other = existing.find { |torrent| torrent["hash"].to_s.downcase != hash }
      if other
        return ServiceResult.failure("Another local torrent is still active. Stop it or clear temporary media in Settings first.")
      end

      add_torrent(hash, title: title, poster_url: poster_url) unless existing.any? { |torrent| torrent["hash"].to_s.casecmp?(hash) }
      torrent = wait_for_metadata(hash)
      return ServiceResult.failure("Torrent metadata could not be loaded. The torrent may have no reachable peers.") unless torrent

      selected_file = select_file(torrent["file_stats"], file_idx: file_idx, filename: filename)
      return ServiceResult.failure("No playable video file was found in this torrent") unless selected_file

      ServiceResult.success(
        streaming_url: stream_url(hash, selected_file),
        filename: File.basename(selected_file.fetch("path")),
        info_hash: hash,
        file_idx: selected_file.fetch("id"),
        source: "local"
      )
    end
  rescue Faraday::TimeoutError, Faraday::ConnectionFailed => error
    Rails.logger.error("[LocalTorrent] TorrServer unavailable: #{error.class}: #{error.message}")
    ServiceResult.failure("The local torrent engine is unavailable")
  rescue StandardError => error
    Rails.logger.error("[LocalTorrent] Start failed: #{error.class}: #{error.message}")
    ServiceResult.failure("Local torrent playback could not be started")
  end

  def live_status(info_hash)
    hash = normalize_hash(info_hash)
    return ServiceResult.failure("Invalid torrent") unless hash

    torrent = list_torrents.find { |item| item["hash"].to_s.casecmp?(hash) }
    return ServiceResult.failure("Local torrent is no longer active") unless torrent

    ServiceResult.success(torrent_status(torrent))
  rescue StandardError => error
    Rails.logger.warn("[LocalTorrent] Live status unavailable: #{error.class}: #{error.message}")
    ServiceResult.failure("Local torrent status is unavailable")
  end

  def status
    return disabled_status unless self.class.enabled?

    ensure_settings!
    torrents = list_torrents
    used_bytes = [ cache_disk_usage, torrents.sum { |torrent| torrent["loaded_size"].to_i } ].max
    {
      enabled: true,
      reachable: true,
      used_bytes: used_bytes,
      quota_bytes: CACHE_BYTES,
      free_bytes: disk_free_bytes,
      minimum_free_bytes: MIN_FREE_BYTES,
      active_count: torrents.count { |torrent| active_torrent?(torrent) },
      torrents: torrents.map { |torrent| torrent_status(torrent) }
    }
  rescue Faraday::Error, StandardError => error
    Rails.logger.warn("[LocalTorrent] Status unavailable: #{error.class}: #{error.message}")
    disabled_status.merge(enabled: true, error: "Local torrent engine is unavailable")
  end

  def clear!
    return ServiceResult.failure("Local torrent playback is disabled") unless self.class.enabled?

    with_start_lock do
      active = list_torrents.any? { |torrent| active_torrent?(torrent) }
      if active
        return ServiceResult.failure("Stop local playback and wait about a minute before clearing temporary media.")
      end

      response = post_json("/torrents", action: "wipe")
      return ServiceResult.failure("Temporary media could not be cleared") unless response.success?

      ServiceResult.success(true)
    end
  rescue Faraday::Error => error
    Rails.logger.error("[LocalTorrent] Clear failed: #{error.class}: #{error.message}")
    ServiceResult.failure("The local torrent engine is unavailable")
  end

  private

  def with_start_lock
    START_MUTEX.synchronize do
      connection = ActiveRecord::Base.connection
      postgres = connection.adapter_name.match?(/postgres/i)
      connection.execute("SELECT pg_advisory_lock(#{START_LOCK_ID})") if postgres
      begin
        yield
      ensure
        connection.execute("SELECT pg_advisory_unlock(#{START_LOCK_ID})") if postgres
      end
    end
  end

  def ensure_settings!
    response = post_json("/settings", action: "get")
    raise "Could not read TorrServer settings" unless response.success? && response.body.is_a?(Hash)

    current = response.body
    desired = current.merge(
      "CacheSize" => CACHE_BYTES,
      "UseDisk" => true,
      "TorrentsSavePath" => "/opt/ts/cache",
      "RemoveCacheOnDrop" => true,
      "TorrentDisconnectTimeout" => DISCONNECT_TIMEOUT,
      "ReaderReadAHead" => 95,
      "ResponsiveMode" => true,
      "ConnectionsLimit" => 50,
      "UploadRateLimit" => UPLOAD_LIMIT_KBPS,
      "EnableDLNA" => false,
      "EnableBonjour" => false
    )
    return if desired == current

    update = post_json("/settings", action: "set", sets: desired)
    raise "Could not configure TorrServer" unless update.success?
  end

  def add_torrent(hash, title:, poster_url:)
    magnet = "magnet:?xt=urn:btih:#{hash}"
    magnet += "&dn=#{CGI.escape(title.to_s)}" if title.present?
    response = post_json(
      "/torrents",
      action: "add",
      link: magnet,
      title: title.to_s.first(300),
      # Do not ask TorrServer to fetch remote artwork. Posters stay in the
      # already-sanitized StreamVault metadata path, avoiding a sidecar SSRF.
      poster: "",
      category: "video",
      save_to_db: false
    )
    raise "TorrServer rejected torrent" unless response.success?
  end

  def wait_for_metadata(hash)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + METADATA_TIMEOUT
    loop do
      response = post_json("/torrents", action: "get", hash: hash)
      if response.success? && response.body.is_a?(Hash) && response.body["file_stats"].present?
        return response.body
      end
      return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.5
    end
  end

  def list_torrents
    response = post_json("/torrents", action: "list")
    return [] unless response.success? && response.body.is_a?(Array)

    response.body
  end

  def select_file(files, file_idx:, filename:)
    candidates = Array(files).select { |file| file["length"].to_i.positive? }
    return nil if candidates.empty?

    requested_name = File.basename(filename.to_s).downcase
    by_name = candidates.find { |file| File.basename(file["path"].to_s).downcase == requested_name } if requested_name.present?
    return by_name if by_name

    requested_idx = Integer(file_idx, exception: false)
    if requested_idx
      # Torrentio fileIdx is commonly zero based; TorrServer file IDs are one
      # based after path sorting. Try both representations before falling back.
      by_index = candidates.find { |file| file["id"].to_i == requested_idx } ||
                 candidates.find { |file| file["id"].to_i == requested_idx + 1 }
      return by_index if by_index && video_file?(by_index["path"])
    end

    video_files = candidates.select { |file| video_file?(file["path"]) }
    video_files.max_by { |file| file["length"].to_i }
  end

  def stream_url(hash, file)
    name = CGI.escape(File.basename(file.fetch("path"))).gsub("+", "%20")
    query = URI.encode_www_form(link: hash, index: file.fetch("id"), play: "")
    "#{self.class.base_url}/stream/#{name}?#{query}"
  end

  def post_json(path, body)
    @connection.post(path, body)
  end

  def normalize_hash(value)
    candidate = value.to_s.strip.downcase
    candidate if candidate.match?(INFO_HASH_FORMAT)
  end

  def video_file?(path)
    VIDEO_EXTENSIONS.include?(File.extname(path.to_s).downcase)
  end

  def enough_disk_space?
    free = disk_free_bytes
    free.nil? || free >= MIN_FREE_BYTES
  end

  def cache_disk_usage
    return 0 unless File.directory?(CACHE_PATH)

    output, status = Open3.capture2("du", "-s", "-B1", CACHE_PATH)
    status.success? ? output.split.first.to_i : 0
  rescue StandardError
    0
  end

  def disk_free_bytes
    path = File.directory?(CACHE_PATH) ? CACHE_PATH : Rails.root
    output, status = Open3.capture2("df", "-B1", "--output=avail", path.to_s)
    status.success? ? output.lines.last.to_i : nil
  rescue StandardError
    nil
  end

  def active_torrent?(torrent)
    torrent["stat_string"].to_s.match?(/added|getting info|working|preload/i)
  end

  def torrent_status(torrent)
    {
      hash: torrent["hash"].to_s,
      title: torrent["title"].presence || torrent["name"].presence || "Local torrent",
      used_bytes: torrent["loaded_size"].to_i,
      total_bytes: torrent["torrent_size"].to_i,
      download_speed: torrent["download_speed"].to_f,
      upload_speed: torrent["upload_speed"].to_f,
      peers: torrent["active_peers"].to_i,
      seeders: torrent["connected_seeders"].to_i,
      state: torrent["stat_string"].to_s
    }
  end

  def disabled_status
    {
      enabled: false,
      reachable: false,
      used_bytes: 0,
      quota_bytes: CACHE_BYTES,
      free_bytes: disk_free_bytes,
      minimum_free_bytes: MIN_FREE_BYTES,
      active_count: 0,
      torrents: []
    }
  end
end
