# frozen_string_literal: true

require "fileutils"
require "securerandom"

# Manages HLS transcoding sessions for iOS Safari playback.
#
# Session metadata (session_id, segment_dir, user_id) is persisted in
# the hls_sessions table so any Puma worker or Dokku process can serve
# playlist/segment requests.  The ffmpeg PID is kept in memory in the
# worker that spawned it — only that worker can kill the process, but
# that's fine: the stop endpoint is best-effort, and the 30-minute TTL
# cleans up orphaned sessions.
#
# Thread-safe: the in-memory PID registry uses a mutex.  DB operations
# go through ActiveRecord's own connection pool.
class HlsSession
  SESSION_TTL = 30.minutes
  SHUTDOWN_GRACE_SECONDS = 1
  ACTIVITY_DEBOUNCE = 30.seconds

  # In-memory PID registry: session_id => pid (only the worker that
  # spawned ffmpeg can kill it).
  @pids = {}
  @mutex = Mutex.new

  # Errors are stored in Rails.cache (shared across all workers via
  # Solid Cache) so the playlist endpoint on worker B can see an error
  # set by the monitor thread on worker A.  The old in-memory @errors
  # hash was per-worker, so under multi-worker the 424 error path
  # never fired if the playlist request landed on a different worker.
  ERROR_CACHE_TTL = 5.minutes
  LOCAL_FIRST_SEGMENT_RETRIES = 1
  LOCAL_RETRY_FIRST_SEGMENT_TIMEOUT_SECONDS = 45

  attr_reader :id, :pid, :segment_dir, :user_id

  def self.create(user_id:, input_url:, headers:, start_seconds:, audio_stream:, subtitle_stream:, default_language:, preferred_languages:, hdr: false)
    session_id = SecureRandom.hex(16)
    dir = Rails.root.join("tmp", "hls", session_id).to_s
    pid = nil

    # Non-blocking: spawn ffmpeg and return immediately. The monitor below
    # detects pre-first-segment failure so the playlist endpoint can return a
    # diagnostic response instead of polling forever.
    begin
      pid = TranscodeService.transcode_to_hls(
        input_url,
        segment_dir: dir,
        headers: headers,
        start_seconds: start_seconds,
        audio_stream: audio_stream,
        subtitle_stream: subtitle_stream,
        default_language: default_language,
        preferred_languages: preferred_languages,
        hdr: hdr,
        wait_for_first_segment: false
      )

      HlsSessionRecord.create!(
        user_id: user_id,
        session_id: session_id,
        segment_dir: dir,
        pid: pid
      )
    rescue StandardError
      # transcode_to_hls creates the directory before it spawns ffmpeg. If
      # persistence fails (or spawning raises), this session still owns both
      # resources and must release them before surfacing the original error.
      terminate_process(pid)
      FileUtils.rm_rf(dir)
      raise
    end

    @mutex.synchronize { @pids[session_id] = pid }
    monitor_first_segment(
      session_id,
      pid,
      dir,
      input_url: input_url,
      headers: headers,
      start_seconds: start_seconds,
      audio_stream: audio_stream,
      subtitle_stream: subtitle_stream,
      default_language: default_language,
      preferred_languages: preferred_languages,
      hdr: hdr
    )

    new(id: session_id, pid: pid, segment_dir: dir, user_id: user_id)
  end

  def self.find(id)
    record = HlsSessionRecord.find_by(session_id: id)
    return nil unless record

    # TTL follows observed playlist/segment activity, not creation time.
    if record.updated_at < SESSION_TTL.ago
      stop(id)
      return nil
    end

    pid = @mutex.synchronize { @pids[id] }
    new(id: record.session_id, pid: pid, segment_dir: record.segment_dir, user_id: record.user_id)
  end
  # Records playlist and segment use at most once per debounce interval. The
  # shared Solid Cache lock is atomic across Puma workers, so concurrent media
  # requests do not each write the session row.
  def self.touch_activity(id)
    return unless Rails.cache.write(
      activity_cache_key(id),
      true,
      expires_in: ACTIVITY_DEBOUNCE,
      unless_exist: true
    )

    HlsSessionRecord.where(session_id: id).update_all(updated_at: Time.current)
  end

  # Returns the error message if ffmpeg failed before producing any
  # segments, or nil if ffmpeg is still starting or succeeded.  Stored
  # in Rails.cache so any worker can read it.
  def self.error(id)
    Rails.cache.read(error_cache_key(id))
  end

  # Store an error for a session in Rails.cache (shared across workers).
  def self.set_error(id, message)
    Rails.cache.write(error_cache_key(id), message, expires_in: ERROR_CACHE_TTL)
  end

  def self.error_cache_key(id)
    "hls_session/error/#{id}"
  end
  def self.activity_cache_key(id)
    "hls_session/activity/#{id}"
  end

  def self.stop(id)
    record = HlsSessionRecord.find_by(session_id: id)
    return unless record

    # Prefer the in-memory PID (same worker that spawned ffmpeg — the
    # only place that can reliably target the process group).  Fall
    # back to the persisted record.pid so the recurring cleanup job
    # (running in the SolidQueue worker, whose @pids is empty) can
    # still kill orphaned ffmpeg processes from other workers.
    pid = @mutex.synchronize { @pids.delete(id) }
    Rails.cache.delete(error_cache_key(id))
    Rails.cache.delete(activity_cache_key(id))
    pid ||= record.pid
    if pid
      HlsSessionKiller.new(pid).kill
    end

    FileUtils.rm_rf(record.segment_dir)
    record.destroy!
  rescue ActiveRecord::RecordNotFound
    # already gone
  end

  def self.cleanup_expired
    HlsSessionRecord.where("updated_at < ?", SESSION_TTL.ago).find_each do |record|
      stop(record.session_id)
    end
  end
  def self.monitor_first_segment(session_id, pid, dir, **transcode_options)
    monitor_thread = Thread.new do
      begin
        local_input = local_torrent_input?(transcode_options[:input_url])
        retries_remaining = local_input ? LOCAL_FIRST_SEGMENT_RETRIES : 0
        timeout_seconds = TranscodeService::FIRST_SEGMENT_TIMEOUT_SECONDS
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds

        loop do
          _, status = Process.waitpid2(pid, Process::WNOHANG)
          if status
            unless status.success? && first_segment_produced?(dir)
              fail_before_first_segment(
                session_id,
                pid,
                dir,
                "FFmpeg exited (status #{status.exitstatus}) without producing segments."
              )
            end
            break
          end

          break if first_segment_produced?(dir)

          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            if retries_remaining.positive?
              retries_remaining -= 1
              replacement_pid = retry_local_transcode(session_id, pid, dir, **transcode_options)
              break unless replacement_pid

              pid = replacement_pid
              timeout_seconds = LOCAL_RETRY_FIRST_SEGMENT_TIMEOUT_SECONDS
              deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
              next
            end

            fail_before_first_segment(
              session_id,
              pid,
              dir,
              "FFmpeg timed out after #{timeout_seconds}s waiting for first segment."
            )
            break
          end

          sleep 0.2
        end
      rescue StandardError => e
        fail_before_first_segment(session_id, pid, dir, e.message)
      end
    end
    monitor_thread.abort_on_exception = false
  end

  def self.first_segment_produced?(dir)
    playlist_path = File.join(dir, "playlist.m3u8")
    File.exist?(playlist_path) && (Dir.glob(File.join(dir, "*.ts")).any? || Dir.glob(File.join(dir, "*.m4s")).any?)
  end

  def self.local_torrent_input?(input_url)
    return false unless LocalTorrentService.enabled?

    uri = URI.parse(input_url.to_s)
    uri.host.to_s.casecmp?(LocalTorrentService.internal_host.to_s)
  rescue URI::InvalidURIError
    false
  end

  # A cold random-access read from TorrServer can spend the whole initial
  # deadline fetching pieces without completing segment zero. Retry once in
  # the same session directory after clearing partial output. The public
  # playlist URL remains stable while the warm piece cache feeds the retry.
  def self.retry_local_transcode(session_id, old_pid, dir, **transcode_options)
    Rails.logger.warn("[HLS] Local first segment timed out for #{session_id}; retrying from warm torrent cache")
    terminate_process(old_pid)
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(dir)

    new_pid = TranscodeService.transcode_to_hls(
      transcode_options.fetch(:input_url),
      segment_dir: dir,
      headers: transcode_options.fetch(:headers),
      start_seconds: transcode_options.fetch(:start_seconds),
      audio_stream: transcode_options[:audio_stream],
      subtitle_stream: transcode_options[:subtitle_stream],
      default_language: transcode_options[:default_language],
      preferred_languages: transcode_options.fetch(:preferred_languages),
      hdr: transcode_options.fetch(:hdr),
      wait_for_first_segment: false
    )

    updated = HlsSessionRecord.where(session_id: session_id, pid: old_pid).update_all(pid: new_pid)
    unless updated.positive?
      terminate_process(new_pid)
      FileUtils.rm_rf(dir)
      return nil
    end

    owned = @mutex.synchronize do
      next false unless @pids[session_id] == old_pid

      @pids[session_id] = new_pid
      true
    end
    return new_pid if owned

    # A concurrent stop removed registry ownership after the DB pid swap.
    # Delete only if the row still points at this replacement; otherwise a
    # newer retry/session owns it. Never leave a DB record for a killed pid.
    HlsSessionRecord.where(session_id: session_id, pid: new_pid).delete_all
    terminate_process(new_pid)
    FileUtils.rm_rf(dir)
    nil
  end

  def self.fail_before_first_segment(session_id, pid, dir, message)
    terminate_process(pid)
    FileUtils.rm_rf(dir)
    removed = HlsSessionRecord.where(session_id: session_id).delete_all
    set_error(session_id, message) if removed.positive?
  ensure
    @mutex.synchronize { @pids.delete(session_id) }
  end

  def self.terminate_process(pid)
    HlsSessionKiller.new(pid).kill if pid
  rescue StandardError => e
    Rails.logger.warn("[HLS] Failed to stop ffmpeg #{pid}: #{e.message}")
  end

  private_class_method :monitor_first_segment, :first_segment_produced?, :local_torrent_input?,
    :retry_local_transcode, :fail_before_first_segment, :terminate_process

  def playlist_path
    File.join(segment_dir, "playlist.m3u8")
  end

  def segment_path(index, format: :ts)
    extension = format == :m4s ? "m4s" : "ts"
    File.join(segment_dir, "#{index.to_i}.#{extension}")
  end

  def init_segment_path
    File.join(segment_dir, "init.mp4")
  end

  # Returns true if the playlist file exists AND contains at least
  # one segment entry.  ffmpeg writes the #EXTM3U header immediately
  # but doesn't add segment lines until the first segment is complete.
  # Checking only File.exist? would treat an empty header-only
  # playlist as ready, causing the client to set it as the video src
  # before any segments are available.
  def playlist_ready?
    return false unless File.exist?(playlist_path)
    content = File.read(playlist_path)
    content.include?("#EXTINF") || content.include?("#EXT-X-ENDLIST")
  rescue StandardError
    false
  end

  private

  def initialize(id:, pid:, segment_dir:, user_id:)
    @id = id
    @pid = pid
    @segment_dir = segment_dir
    @user_id = user_id
  end
end

# Helper class to kill an ffmpeg process group.
class HlsSessionKiller
  def initialize(pid)
    @pid = pid
  end

  def kill
    return if @pid.nil?

    signal_group("CONT")
    signaled = signal_group("TERM")
    return unless signaled

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HlsSession::SHUTDOWN_GRACE_SECONDS
    while group_alive?
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.05
    end

    signal_group("KILL") if group_alive?
    waitpid_safely
  end

  private

  def signal_group(sig)
    Process.kill(sig, -@pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def group_alive?
    Process.kill(0, -@pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def waitpid_safely
    Process.wait(@pid)
  rescue Errno::ESRCH, Errno::ECHILD
  end
end
