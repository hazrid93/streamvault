# frozen_string_literal: true

require "rails_helper"

RSpec.describe HlsSession do
  let(:user) { create(:user) }
  let(:session_id) { "hls-service-#{SecureRandom.hex(8)}" }
  let(:segment_dir) { Rails.root.join("tmp", "hls", session_id).to_s }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(Rails).to receive(:cache).and_return(cache)
  end

  after do
    FileUtils.rm_rf(segment_dir)
  end

  describe ".create" do
    let(:pid) { 45_678 }
    let(:killer) { instance_double(HlsSessionKiller, kill: nil) }

    before do
      allow(SecureRandom).to receive(:hex).with(16).and_return(session_id)
      allow(TranscodeService).to receive(:transcode_to_hls) do |_input_url, **kwargs|
        FileUtils.mkdir_p(kwargs.fetch(:segment_dir))
        pid
      end
      allow(HlsSessionKiller).to receive(:new).with(pid).and_return(killer)
    end

    it "cleans up the ffmpeg process and segment directory when persistence fails" do
      allow(HlsSessionRecord).to receive(:create!).and_raise(
        ActiveRecord::RecordInvalid.new(HlsSessionRecord.new)
      )

      expect { create_session }.to raise_error(ActiveRecord::RecordInvalid)

      expect(killer).to have_received(:kill)
      expect(File.exist?(segment_dir)).to be(false)
      expect(HlsSessionRecord.find_by(session_id: session_id)).to be_nil
    end

    it "cleans up a pre-first-segment ffmpeg failure and retains diagnostics" do
      run_monitor_inline
      status = instance_double(Process::Status, success?: false, exitstatus: 1)
      allow(Process).to receive(:waitpid2).with(pid, Process::WNOHANG).and_return([pid, status])

      session = create_session

      expect(session.id).to eq(session_id)
      expect(killer).to have_received(:kill)
      expect(File.exist?(segment_dir)).to be(false)
      expect(HlsSessionRecord.find_by(session_id: session_id)).to be_nil
      expect(described_class.error(session_id)).to include("FFmpeg exited (status 1)")
    end

    it "terminates a first-segment timeout and retains diagnostics" do
      run_monitor_inline
      stub_const("TranscodeService::FIRST_SEGMENT_TIMEOUT_SECONDS", 0)
      allow(Process).to receive(:waitpid2).with(pid, Process::WNOHANG).and_return([nil, nil])

      create_session

      expect(killer).to have_received(:kill)
      expect(File.exist?(segment_dir)).to be(false)
      expect(HlsSessionRecord.find_by(session_id: session_id)).to be_nil
      expect(described_class.error(session_id)).to include("timed out")
    end
  end

  describe "activity expiry" do
    it "keeps an old but recently active session out of expiry cleanup" do
      record = create(
        :hls_session_record,
        user: user,
        session_id: session_id,
        segment_dir: segment_dir,
        created_at: (described_class::SESSION_TTL + 1.minute).ago,
        updated_at: Time.current
      )

      expect(described_class.find(session_id)).to have_attributes(id: session_id)

      described_class.cleanup_expired

      expect(HlsSessionRecord.find_by(id: record.id)).to be_present
    end

    it "atomically debounces activity writes across shared workers" do
      create(:hls_session_record, user: user, session_id: session_id, segment_dir: segment_dir)
      activity_key = described_class.activity_cache_key(session_id)

      expect(cache).to receive(:write)
        .with(activity_key, true, expires_in: described_class::ACTIVITY_DEBOUNCE, unless_exist: true)
        .twice
        .and_call_original
      expect(HlsSessionRecord).to receive(:where).with(session_id: session_id).once.and_call_original

      2.times { described_class.touch_activity(session_id) }
    end
  end

  private

  def create_session
    described_class.create(
      user_id: user.id,
      input_url: "https://download.real-debrid.com/d/file123/video.mkv",
      headers: {},
      start_seconds: 0,
      audio_stream: nil,
      subtitle_stream: nil,
      default_language: nil,
      preferred_languages: []
    )
  end

  def run_monitor_inline
    monitor_thread = instance_double(Thread)
    allow(monitor_thread).to receive(:abort_on_exception=)
    allow(Thread).to receive(:new) do |&block|
      block.call
      monitor_thread
    end
  end
end
