# frozen_string_literal: true

class RealDebridService
  BASE_URL = ENV.fetch("REALDEBRID_API_BASE_URL", "https://api.real-debrid.com/rest/1.0")
  MAX_RETRIES = 3
  RETRY_DELAY = 2

  def initialize(api_key)
    @api_key = api_key
    @conn = Faraday.new(url: BASE_URL) do |f|
      f.request :url_encoded
      f.response :json
      f.adapter Faraday.default_adapter
      f.options.timeout = 30
      f.options.open_timeout = 10
      f.headers["Authorization"] = "Bearer #{api_key}"
    end
  end

  # Verify the API key is valid
  def verify_key
    response = @conn.get("user")
    if response.success?
      ServiceResult.success(response.body)
    else
      ServiceResult.failure(parse_error(response), response.status)
    end
  rescue Faraday::TimeoutError
    ServiceResult.failure("Request timed out")
  rescue StandardError => e
    Rails.logger.error("RealDebridService#verify_key error: #{e.message}")
    ServiceResult.failure("Failed to verify API key")
  end

  # Unrestrict a link to get a direct download/streaming URL
  def unrestrict_link(url)
    return ServiceResult.failure("URL is required") if url.blank?

    response = with_retry do
      @conn.post("unrestrict/link") do |req|
        req.body = { link: url }
      end
    end

    if response.success?
      ServiceResult.success({
        download_link: response.body["download"],
        filename: response.body["filename"],
        filesize: response.body["filesize"],
        mimeType: response.body["mimeType"]
      })
    else
      ServiceResult.failure(parse_error(response), response.status)
    end
  rescue StandardError => e
    Rails.logger.error("RealDebridService#unrestrict_link error: #{e.message}")
    ServiceResult.failure("Failed to unrestrict link")
  end

  # Add a magnet link to RealDebrid
  def add_magnet(magnet)
    return ServiceResult.failure("Magnet link is required") if magnet.blank?

    response = with_retry do
      @conn.post("torrents/addMagnet") do |req|
        req.body = { magnet: magnet }
      end
    end

    if response.success?
      ServiceResult.success({
        id: response.body["id"],
        uri: response.body["uri"]
      })
    else
      ServiceResult.failure(parse_error(response), response.status)
    end
  rescue StandardError => e
    Rails.logger.error("RealDebridService#add_magnet error: #{e.message}")
    ServiceResult.failure("Failed to add magnet")
  end

  # Get torrent info (status, files, links)
  def torrent_info(id)
    return ServiceResult.failure("Torrent ID is required") if id.blank?

    response = @conn.get("torrents/info/#{id}")

    if response.success?
      ServiceResult.success(normalize_torrent_info(response.body))
    else
      ServiceResult.failure(parse_error(response), response.status)
    end
  rescue StandardError => e
    Rails.logger.error("RealDebridService#torrent_info error: #{e.message}")
    ServiceResult.failure("Failed to get torrent info")
  end

  # Select files to download from a torrent
  def select_files(id, file_ids)
    return ServiceResult.failure("Torrent ID and file IDs are required") if id.blank? || file_ids.blank?

    response = with_retry do
      @conn.post("torrents/selectFiles/#{id}") do |req|
        req.body = { files: Array(file_ids).join(",") }
      end
    end

    if response.success? || response.status == 204
      ServiceResult.success(true)
    else
      ServiceResult.failure(parse_error(response), response.status)
    end
  rescue StandardError => e
    Rails.logger.error("RealDebridService#select_files error: #{e.message}")
    ServiceResult.failure("Failed to select files")
  end

  private

  def parse_error(response)
    return "Unknown error" unless response.body.is_a?(Hash)
    response.body["error"] || "Request failed with status #{response.status}"
  rescue
    "Request failed with status #{response.status}"
  end

  def normalize_torrent_info(data)
    {
      id: data["id"],
      filename: data["filename"],
      status: data["status"],
      progress: data["progress"],
      files: (data["files"] || []).map do |f|
        { id: f["id"], path: f["path"], bytes: f["bytes"], selected: f["selected"] == 1 }
      end,
      links: data["links"] || [],
      speed: data["speed"],
      seeders: data["seeders"]
    }
  end

  def with_retry
    retries = 0

    loop do
      response =
        begin
          yield
        rescue Faraday::TimeoutError, Faraday::ConnectionFailed
          retries += 1
          raise if retries > MAX_RETRIES

          sleep(RETRY_DELAY * retries)
          next
        end

      return response if response.status != 429 || retries >= MAX_RETRIES

      retries += 1
      sleep(RETRY_DELAY * retries)
    end
  end
end
