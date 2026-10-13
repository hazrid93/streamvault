# frozen_string_literal: true

class TranscodeService
  # Embedded subtitle tracks: choosing selectable tracks and extracting
  # time windows of text subtitles as WebVTT. Extended into TranscodeService,
  # so these run as its class methods and share its probe cache and process
  # helpers.
  module Subtitles
    def extract_subtitle_stream_start_times(output)
      data = JSON.parse(output)
      Array(data["streams"]).each_with_object({}) do |stream, starts|
        next unless stream["codec_type"].to_s == "subtitle"

        stream_index = non_negative_integer(stream["index"])
        start_time = finite_float(stream["start_time"])
        starts[stream_index] = start_time if stream_index && start_time
      end
    rescue JSON::ParserError
      {}
    end
    private :extract_subtitle_stream_start_times

    def cached_subtitle_stream_start_time(input_url, stream_index, headers: {})
      start_time = cache_get(input_url, headers: headers)&.dig(:subtitle_stream_start_times, stream_index)
      start_time.is_a?(Numeric) && start_time.finite? ? start_time : 0
    end
    private :cached_subtitle_stream_start_time

    def extract_subtitles_to_vtt(input_url, headers: {}, subtitle_stream: nil, start_seconds: 0, duration_seconds: SUBTITLE_EXTRACTION_WINDOW_SECONDS)
      extract_subtitles(
        input_url,
        headers: headers,
        subtitle_stream: subtitle_stream,
        start_seconds: start_seconds,
        duration_seconds: duration_seconds
      ).vtt.to_s
    end

    def extract_subtitles(input_url, headers: {}, subtitle_stream: nil, start_seconds: 0, duration_seconds: SUBTITLE_EXTRACTION_WINDOW_SECONDS)
      stream_index = normalized_stream_index(subtitle_stream)
      seek_start_seconds = normalized_start_seconds(start_seconds)
      extraction_duration_seconds = normalized_subtitle_duration_seconds(duration_seconds)
      unless stream_index
        result = subtitle_result(:invalid_stream, diagnostic: "invalid subtitle stream")
        log_subtitle_result(result, stream_index: subtitle_stream, start_seconds: seek_start_seconds)
        return result
      end

      track = probe_media_tracks(input_url, headers: headers)[:subtitles].find { |subtitle| subtitle[:index] == stream_index }
      subtitle_stream_start_time = cached_subtitle_stream_start_time(input_url, stream_index, headers: headers)

      unless track
        result = subtitle_result(:unsupported_track, diagnostic: "subtitle stream was not found")
        log_subtitle_result(result, stream_index: stream_index, start_seconds: seek_start_seconds)
        return result
      end

      unless track[:text_supported]
        result = subtitle_result(:unsupported_track, diagnostic: "subtitle stream is not text based")
        log_subtitle_result(result, stream_index: stream_index, start_seconds: seek_start_seconds)
        return result
      end

      packet_subtitles = extract_subtitle_packets_to_vtt(
        input_url,
        headers: headers,
        track: track,
        start_seconds: seek_start_seconds,
        duration_seconds: extraction_duration_seconds
      )
      if packet_subtitles.ok? || packet_subtitles.empty_window? || packet_subtitles.status == :timeout
        log_subtitle_result(packet_subtitles, stream_index: stream_index, start_seconds: seek_start_seconds)
        return packet_subtitles
      end

      header_str = ffmpeg_headers(headers)
      cmd = [ FFMPEG_PATH, "-loglevel", "error" ]
      cmd += [ "-analyzeduration", "1000000", "-probesize", "1000000" ]
      cmd += [ "-headers", header_str + "\r\n" ] if header_str.present?
      cmd += [ "-ss", seek_start_seconds.to_s ] if seek_start_seconds.positive?
      cmd += [
        "-i", input_url,
        "-t", extraction_duration_seconds.to_s,
        "-vn",
        "-an",
        "-dn",
        "-map", "0:#{stream_index}",
        "-c:s", "webvtt"
      ]
      # Input seeking and stream start timestamps can both make FFmpeg's
      # fallback VTT timestamps relative to the subtitle stream. Shift the
      # muxed output back onto the source timeline used by packet extraction.
      output_timestamp_offset = seek_start_seconds + subtitle_stream_start_time
      cmd += [ "-output_ts_offset", output_timestamp_offset.to_s ] unless output_timestamp_offset.zero?
      cmd += [
        "-f", "webvtt",
        "pipe:1"
      ]

      result = capture_subtitle_stdout_result(cmd)
      log_subtitle_result(result, stream_index: stream_index, start_seconds: seek_start_seconds)
      result
    rescue StandardError => e
      result = subtitle_result(:failed, diagnostic: e.class.name)
      log_subtitle_result(result, stream_index: subtitle_stream, start_seconds: start_seconds)
      result
    end

    def selectable_subtitle_tracks(tracks)
      tracks = Array(tracks)
      full_tracks = tracks.reject { |track| partial_subtitle_track?(track) }
      return sorted_subtitle_tracks(tracks) if full_tracks.empty?

      filtered_tracks = tracks.reject do |track|
        partial_subtitle_track?(track) && full_dialogue_alternative?(track, full_tracks)
      end
      sorted_subtitle_tracks(filtered_tracks)
    end

    def extract_subtitle_packets_to_vtt(input_url, headers:, track:, start_seconds:, duration_seconds:)
      header_str = ffmpeg_headers(headers)
      cmd = [ FFPROBE_PATH, "-v", "error" ]
      cmd += [ "-headers", header_str + "\r\n" ] if header_str.present?
      cmd += [
        "-select_streams", track[:index].to_s,
        "-read_intervals", "#{start_seconds}%+#{duration_seconds}",
        "-show_entries", "packet=pts_time,duration_time,data",
        "-show_data",
        "-of", "json",
        input_url
      ]

      result = capture_command(cmd, timeout_seconds: SUBTITLE_PACKET_EXTRACTION_TIMEOUT_SECONDS)
      return subtitle_result(:timeout, source: :ffprobe_packets, diagnostic: "ffprobe packet extraction timed out") if result.timed_out
      return subtitle_result(:failed, source: :ffprobe_packets, diagnostic: "ffprobe packets exited unsuccessfully") unless result.status&.success?

      packet_result = subtitle_packets_to_webvtt(result.stdout, track[:codec], start_seconds, duration_seconds)
      if packet_result[:failed]
        subtitle_result(:failed, source: :ffprobe_packets, diagnostic: packet_result[:diagnostic])
      elsif packet_result[:cue_count].positive?
        subtitle_result(:ok, vtt: packet_result[:vtt], cue_count: packet_result[:cue_count], source: :ffprobe_packets)
      elsif packet_result[:packet_count].positive?
        subtitle_result(:failed, source: :ffprobe_packets, diagnostic: "ffprobe packets had no decodable text cues")
      else
        subtitle_result(:empty_window, source: :ffprobe_packets)
      end
    rescue StandardError => e
      subtitle_result(:failed, source: :ffprobe_packets, diagnostic: e.class.name)
    end
    private :extract_subtitle_packets_to_vtt

    def subtitle_packets_to_webvtt(output, codec, start_seconds, duration_seconds)
      data = JSON.parse(output)
      window_start = [ start_seconds - 5, 0 ].max
      window_end = start_seconds + duration_seconds
      cues = Array(data["packets"]).filter_map do |packet|
        subtitle_packet_to_cue(packet, codec, window_start, window_end)
      end

      {
        vtt: webvtt_from_cues(cues),
        cue_count: cues.length,
        packet_count: Array(data["packets"]).length
      }
    rescue JSON::ParserError
      { vtt: "", cue_count: 0, packet_count: 0, failed: true, diagnostic: "ffprobe packet JSON could not be parsed" }
    end
    private :subtitle_packets_to_webvtt

    def subtitle_packet_to_cue(packet, codec, window_start, window_end)
      start_time = finite_float(packet["pts_time"])
      return nil unless start_time

      duration = finite_float(packet["duration_time"]) || SUBTITLE_FALLBACK_DURATION_SECONDS
      duration = SUBTITLE_FALLBACK_DURATION_SECONDS unless duration.positive?
      end_time = start_time + duration
      return nil if end_time < window_start || start_time > window_end

      text = subtitle_packet_text(packet["data"], codec)
      return nil if text.blank?

      { start: start_time, end: end_time, text: text }
    end
    private :subtitle_packet_to_cue

    def subtitle_packet_text(data, codec)
      text = decode_ffprobe_packet_data(data)
      return "" if text.blank?

      text = ass_packet_text(text) if %w[ass ssa].include?(codec.to_s)
      normalize_subtitle_text(text)
    end
    private :subtitle_packet_text

    def decode_ffprobe_packet_data(data)
      bytes = data.to_s.each_line.flat_map do |line|
        hex = line[/:\s*((?:[[:xdigit:]]{2,4}\s*)+)/, 1]
        hex ? hex.scan(/[[:xdigit:]]{2}/).map { |byte| byte.to_i(16) } : []
      end
      bytes.pack("C*").force_encoding(Encoding::UTF_8).scrub
    end
    private :decode_ffprobe_packet_data

    def ass_packet_text(text)
      text.split(",", 9).last.to_s
    end
    private :ass_packet_text

    def normalize_subtitle_text(text)
      text
        .gsub(/\{[^}]*\}/, "")
        .gsub(/\\[Nn]/, "\n")
        .gsub(/<[^>]+>/, "")
        .lines
        .map(&:strip)
        .reject(&:blank?)
        .join("\n")
    end
    private :normalize_subtitle_text

    def webvtt_from_cues(cues)
      return "" if cues.empty?

      body = cues
        .sort_by { |cue| cue[:start] }
        .map do |cue|
          "#{format_vtt_timestamp(cue[:start])} --> #{format_vtt_timestamp(cue[:end])}\n#{cue[:text]}"
        end
        .join("\n\n")
      "WEBVTT\n\n#{body}\n"
    end
    private :webvtt_from_cues

    def format_vtt_timestamp(seconds)
      milliseconds = (seconds.to_f * 1000).round
      hours = milliseconds / 3_600_000
      milliseconds %= 3_600_000
      minutes = milliseconds / 60_000
      milliseconds %= 60_000
      whole_seconds = milliseconds / 1000
      milliseconds %= 1000

      format("%02d:%02d:%02d.%03d", hours, minutes, whole_seconds, milliseconds)
    end
    private :format_vtt_timestamp

    def capture_subtitle_stdout(cmd)
      capture_subtitle_stdout_result(cmd).vtt.to_s
    end
    private :capture_subtitle_stdout

    def capture_subtitle_stdout_result(cmd)
      rd, wr = IO.pipe
      err_rd, err_wr = IO.pipe
      pid = Process.spawn(*cmd, in: "/dev/null", out: wr, err: err_wr, pgroup: true)
      wr.close
      err_wr.close

      stdout_buf = +""
      reaped = false

      stdout_thread = Thread.new do
        loop do
          chunk = rd.readpartial(4096)
          stdout_buf << chunk
        end
      rescue EOFError, IOError, Errno::EBADF
      end

      stderr_thread = Thread.new do
        loop { err_rd.readpartial(4096) }
      rescue EOFError, IOError, Errno::EBADF
      end

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SUBTITLE_EXTRACTION_TIMEOUT_SECONDS
      loop do
        _, status = Process.waitpid2(pid, Process::WNOHANG)
        if status
          reaped = true
          stdout_thread.join(1)
          stderr_thread.join(1)
          return subtitle_result(:ok, vtt: stdout_buf, cue_count: webvtt_cue_count(stdout_buf), source: :ffmpeg) if status.success? && webvtt_has_cues?(stdout_buf)
          return subtitle_result(:empty_window, source: :ffmpeg) if status.success?

          return subtitle_result(:failed, source: :ffmpeg, diagnostic: "ffmpeg subtitle extraction exited unsuccessfully")
        end

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          return subtitle_result(:ok, vtt: stdout_buf, cue_count: webvtt_cue_count(stdout_buf), source: :ffmpeg) if webvtt_has_cues?(stdout_buf)

          return subtitle_result(:timeout, source: :ffmpeg, diagnostic: "ffmpeg subtitle extraction timed out")
        end

        sleep 0.1
      end
    ensure
      kill_process_group(pid) if pid && !reaped
      stdout_thread&.kill
      stderr_thread&.kill
      stdout_thread&.join(1)
      stderr_thread&.join(1)
      rd&.close unless rd&.closed?
      err_rd&.close unless err_rd&.closed?
    end
    private :capture_subtitle_stdout_result

    def webvtt_has_cues?(text)
      text.to_s.match?(/^\d{2}:\d{2}(?::\d{2})?[\.,]\d{3}\s+-->/)
    end
    private :webvtt_has_cues?

    def webvtt_cue_count(text)
      text.to_s.scan(/^\d{2}:\d{2}(?::\d{2})?[\.,]\d{3}\s+-->/).length
    end
    private :webvtt_cue_count

    def subtitle_result(status, vtt: "", cue_count: 0, source: nil, diagnostic: nil)
      SubtitleExtractionResult.new(
        status: status,
        vtt: vtt.to_s,
        cue_count: cue_count.to_i,
        source: source,
        diagnostic: diagnostic
      )
    end
    private :subtitle_result

    def log_subtitle_result(result, stream_index:, start_seconds:)
      return unless defined?(Rails)

      Rails.logger.info(
        "[Subtitles] status=#{result.status} source=#{result.source || 'none'} " \
        "stream=#{stream_index.presence || 'none'} start=#{normalized_start_seconds(start_seconds)} " \
        "cues=#{result.cue_count}"
      )
    end
    private :log_subtitle_result

    def annotate_subtitle_track!(track, stream)
      disposition = stream["disposition"] || {}
      title = track[:title].to_s
      forced = truthy_disposition?(disposition, "forced") || title.match?(/\bforced\b/i)
      hearing_impaired = truthy_disposition?(disposition, "hearing_impaired") || title.match?(HEARING_IMPAIRED_TITLE_PATTERN)
      commentary = truthy_disposition?(disposition, "comment") || title.match?(/\bcomment(?:ary)?\b/i)
      lyrics = truthy_disposition?(disposition, "lyrics") || truthy_disposition?(disposition, "karaoke") || title.match?(/\b(?:lyrics?|karaoke)\b/i)
      partial = forced || commentary || lyrics || title.match?(PARTIAL_SUBTITLE_TITLE_PATTERN)

      track[:forced] = forced
      track[:hearing_impaired] = hearing_impaired
      track[:commentary] = commentary
      track[:partial] = partial
      track[:quality] = partial ? "partial" : "full"
      track[:quality_score] = subtitle_quality_score(track)
      track[:label] = subtitle_track_label(track)
    end
    private :annotate_subtitle_track!

    def truthy_disposition?(disposition, key)
      disposition[key].to_i == 1
    end
    private :truthy_disposition?

    def partial_subtitle_track?(track)
      track[:partial] == true || track["partial"] == true
    end
    private :partial_subtitle_track?

    def full_dialogue_alternative?(track, full_tracks)
      language = track[:language] || track["language"]
      return full_tracks.any? if language.blank?

      full_tracks.any? { |candidate| (candidate[:language] || candidate["language"]) == language }
    end
    private :full_dialogue_alternative?

    def sorted_subtitle_tracks(tracks)
      tracks.sort_by do |track|
        [
          track[:quality_score] || track["quality_score"] || 0,
          track[:external] || track["external"] ? 0 : 1,
          track[:position] || track["position"] || MAX_STREAM_INDEX,
          track[:label] || track["label"].to_s
        ]
      end
    end
    private :sorted_subtitle_tracks

    def subtitle_quality_score(track)
      score = 0
      score += 100 if track[:partial]
      score += 20 if track[:hearing_impaired]
      score += 10 unless track[:text_supported]
      score -= 5 if track[:default]
      score
    end
    private :subtitle_quality_score

    def subtitle_track_label(track)
      parts = [ language_label(track[:language]) ]
      parts << track[:title] if track[:title].present?
      parts << "Forced" if track[:forced] && !track[:title].to_s.match?(/\bforced\b/i)
      parts << "SDH" if track[:hearing_impaired] && !track[:title].to_s.match?(HEARING_IMPAIRED_TITLE_PATTERN)
      parts << "Partial" if track[:partial] && !track[:forced] && !track[:commentary]
      parts << track[:codec].upcase if track[:codec].present?
      parts << "Default" if track[:default]
      parts.compact_blank.uniq.join(" · ")
    end
    private :subtitle_track_label

    def normalized_subtitle_duration_seconds(value)
      seconds = value.to_i
      return SUBTITLE_EXTRACTION_WINDOW_SECONDS unless seconds.positive?

      seconds.clamp(MIN_SUBTITLE_EXTRACTION_WINDOW_SECONDS, MAX_SUBTITLE_EXTRACTION_WINDOW_SECONDS)
    end
    private :normalized_subtitle_duration_seconds
  end
end
