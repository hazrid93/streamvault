# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe TranscodeService, ".extract_thumbnail" do
  let(:input_url) { "https://download.real-debrid.com/d/file123/movie.mkv" }
  let(:jpeg) { "\xFF\xD8\xFFpreview\xFF\xD9".b }

  before do
    described_class.instance_variable_set(:@thumbnail_cache, {})
    described_class.instance_variable_set(:@thumbnail_cache_bytes, 0)
    described_class.instance_variable_set(:@thumbnail_inflight, {})
    described_class.instance_variable_set(:@thumbnail_active_captures, 0)
  end

  it "uses sanitized headers and fast input seeking to emit one bounded JPEG frame" do
    command = nil
    allow(described_class).to receive(:capture_command) do |cmd, **kwargs|
      command = cmd
      expect(kwargs[:timeout_seconds]).to eq(described_class::THUMBNAIL_TIMEOUT_SECONDS)
      capture_result(jpeg)
    end

    output = described_class.extract_thumbnail(
      input_url,
      headers: {
        "Authorization" => "Bearer token",
        "Injected\r\nHeader" => "ignored",
        "Also-Bad" => "value\r\nignored"
      },
      timestamp: 42
    )

    expect(output).to eq(jpeg)
    expect(argument_pairs(command)).to include(
      [ "-headers", "Authorization: Bearer token\r\n" ],
      [ "-probesize", "1M" ],
      [ "-analyzeduration", "2000000" ],
      [ "-ss", "42" ],
      [ "-skip_frame", "nokey" ],
      [ "-i", input_url ],
      [ "-map", "0:v:0" ],
      [ "-frames:v", "1" ],
      [ "-vf", described_class::THUMBNAIL_FILTER ],
      [ "-c:v", "mjpeg" ],
      [ "-f", "image2pipe" ]
    )
    expect(command.index("-ss")).to be < command.index("-i")
    expect(command).to include("-noaccurate_seek", "-an", "-sn", "-dn", "pipe:1")
    expect(command.count("-frames:v")).to eq(1)
    expect(command.join(" ")).not_to include("Injected", "Also-Bad", "ignored")
  end

  it "rejects invalid service-level timestamps before spawning FFmpeg" do
    expect(described_class).not_to receive(:capture_command)

    [ -1, 86_401, "bad", Float::NAN, Float::INFINITY ].each do |timestamp|
      expect {
        described_class.extract_thumbnail(input_url, timestamp: timestamp)
      }.to raise_error(described_class::ThumbnailExtractionError, "Invalid thumbnail timestamp")
    end
  end

  it "distinguishes capture timeouts from other failures" do
    allow(described_class).to receive(:capture_command).and_return(capture_result("", timed_out: true))

    expect {
      described_class.extract_thumbnail(input_url, timestamp: 10)
    }.to raise_error(described_class::ThumbnailTimeoutError)

    allow(described_class).to receive(:capture_command).and_return(capture_result("", success: false))
    expect {
      described_class.extract_thumbnail(input_url, timestamp: 11)
    }.to raise_error(described_class::ThumbnailExtractionError)
  end

  it "rejects empty, non-JPEG, truncated, and oversized output" do
    outputs = [
      "",
      "not an image",
      "\xFF\xD8\xFFtruncated".b,
      "\xFF\xD8\xFF".b + ("x" * described_class::THUMBNAIL_MAX_BYTES) + "\xFF\xD9".b
    ]

    outputs.each_with_index do |output, timestamp|
      allow(described_class).to receive(:capture_command).and_return(capture_result(output))
      expect {
        described_class.extract_thumbnail(input_url, timestamp: timestamp)
      }.to raise_error(described_class::ThumbnailExtractionError)
    end
  end

  it "caches successful frames but isolates credentials and timestamps" do
    calls = 0
    allow(described_class).to receive(:capture_command) do
      calls += 1
      capture_result(jpeg)
    end

    alpha_headers = { "Authorization" => "Bearer alpha" }
    beta_headers = { "Authorization" => "Bearer beta" }
    2.times { described_class.extract_thumbnail(input_url, headers: alpha_headers, timestamp: 20) }
    described_class.extract_thumbnail(input_url, headers: beta_headers, timestamp: 20)
    described_class.extract_thumbnail(input_url, headers: alpha_headers, timestamp: 21)

    expect(calls).to eq(3)
    expect(described_class.instance_variable_get(:@thumbnail_cache).size).to eq(3)
  end

  it "keeps the successful-result cache bounded" do
    stub_const("TranscodeService::THUMBNAIL_CACHE_MAX_SIZE", 3)
    allow(described_class).to receive(:capture_command).and_return(capture_result(jpeg))

    5.times { |timestamp| described_class.extract_thumbnail(input_url, timestamp: timestamp) }

    expect(described_class.instance_variable_get(:@thumbnail_cache).size).to eq(3)
  end

  it "bounds the cache by total JPEG bytes" do
    stub_const("TranscodeService::THUMBNAIL_CACHE_MAX_BYTES", jpeg.bytesize * 2)
    allow(described_class).to receive(:capture_command).and_return(capture_result(jpeg))

    3.times { |timestamp| described_class.extract_thumbnail(input_url, timestamp: timestamp) }

    expect(described_class.instance_variable_get(:@thumbnail_cache).size).to eq(2)
    expect(described_class.instance_variable_get(:@thumbnail_cache_bytes)).to eq(jpeg.bytesize * 2)
  end

  it "expires cached frames after the TTL" do
    now = 100.0
    calls = 0
    allow(described_class).to receive(:monotonic_now) { now }
    allow(described_class).to receive(:capture_command) do
      calls += 1
      capture_result(jpeg)
    end

    described_class.extract_thumbnail(input_url, timestamp: 10)
    now += described_class::THUMBNAIL_CACHE_TTL_SECONDS + 1
    described_class.extract_thumbnail(input_url, timestamp: 10)

    expect(calls).to eq(2)
  end

  it "rejects excess distinct captures instead of filling request threads" do
    stub_const("TranscodeService::THUMBNAIL_MAX_CONCURRENT_CAPTURES", 1)
    started = Queue.new
    release = Queue.new
    allow(described_class).to receive(:capture_command) do
      started << true
      release.pop
      capture_result(jpeg)
    end

    first = Thread.new { described_class.extract_thumbnail(input_url, timestamp: 30) }
    Timeout.timeout(2) { started.pop }

    expect {
      described_class.extract_thumbnail(input_url, timestamp: 31)
    }.to raise_error(described_class::ThumbnailBusyError)

    release << true
    expect(first.value).to eq(jpeg)
    expect(described_class.instance_variable_get(:@thumbnail_active_captures)).to eq(0)
  ensure
    release << true if release
    first&.kill if first&.alive?
  end

  it "shares an identical in-flight extraction" do
    started = Queue.new
    release = Queue.new
    calls = 0
    calls_mutex = Mutex.new
    allow(described_class).to receive(:capture_command) do
      calls_mutex.synchronize { calls += 1 }
      started << true
      release.pop
      capture_result(jpeg)
    end

    first = Thread.new { described_class.extract_thumbnail(input_url, timestamp: 30) }
    Timeout.timeout(2) { started.pop }
    second = Thread.new { described_class.extract_thumbnail(input_url, timestamp: 30) }
    sleep 0.05
    expect(calls_mutex.synchronize { calls }).to eq(1)

    release << true
    expect([ first.value, second.value ]).to eq([ jpeg, jpeg ])
    expect(calls_mutex.synchronize { calls }).to eq(1)
  ensure
    2.times { release << true } if release
    first&.kill if first&.alive?
    second&.kill if second&.alive?
  end

  def argument_pairs(command)
    command.each_cons(2).to_a
  end

  def capture_result(stdout, success: true, timed_out: false)
    status = timed_out ? nil : instance_double(Process::Status, success?: success)
    described_class::CommandCaptureResult.new(
      stdout: stdout,
      stderr: "sensitive ffmpeg diagnostic",
      status: status,
      timed_out: timed_out
    )
  end
end
