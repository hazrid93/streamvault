# frozen_string_literal: true

require "rails_helper"

RSpec.describe LiveCaptionTranslationService do
  let(:input_url) { "https://download.real-debrid.com/d/file123/movie.mkv" }
  let(:endpoint) { "http://whisper.test:8080/inference" }
  let(:success_payload) do
    {
      task: "translate",
      language: "french",
      detected_language: "french",
      language_probabilities: { fr: 0.93, en: 0.04 },
      segments: [
        { text: " Hello there. ", start: 0.5, end: 3.2, no_speech_prob: 0.01, avg_logprob: -0.2 },
        { text: "Outside the clip", start: 29.0, end: 34.0, no_speech_prob: 0.02, avg_logprob: -0.3 },
        { text: "hallucination", start: 8.0, end: 10.0, no_speech_prob: 0.95, avg_logprob: -1.4 }
      ]
    }.to_json
  end

  around do |example|
    old_enabled = ENV["LIVE_CAPTIONS_ENABLED"]
    old_url = ENV["LIVE_CAPTION_WHISPER_URL"]
    ENV["LIVE_CAPTIONS_ENABLED"] = "true"
    ENV["LIVE_CAPTION_WHISPER_URL"] = endpoint
    described_class.reset_cache!
    example.run
  ensure
    ENV["LIVE_CAPTIONS_ENABLED"] = old_enabled
    ENV["LIVE_CAPTION_WHISPER_URL"] = old_url
    described_class.reset_cache!
  end

  before do
    allow(TranscodeService).to receive(:extract_speech_audio) do |_url, output_path:, **_kwargs|
      File.binwrite(output_path, "RIFF" + ("\0" * 128))
      TranscodeService::AudioClipExtractionResult.new(status: :ok, bytes: File.size(output_path))
    end
  end

  it "rebases relative segments to the requested source window and clamps overshoot" do
    request = stub_request(:post, endpoint).to_return(status: 200, body: success_payload, headers: { "Content-Type" => "application/json" })

    result = described_class.new.translate(input_url, start_seconds: 52)

    expect(result).to be_ok
    expect(result.window_start).to eq(52)
    expect(result.window_end).to eq(82)
    expect(result.source_language).to eq("fr")
    expect(result.cues).to eq([
      { start: 52.5, end: 55.2, text: "Hello there." },
      { start: 81.0, end: 82.0, text: "Outside the clip" }
    ])
    expect(request).to have_been_requested.once
    expect(WebMock::RequestRegistry.instance.requested_signatures.hash.keys.first.body).to include(
      'name="response_format"', "verbose_json", 'name="translate"', 'name="language"', "auto"
    )
  end

  it "clamps cues to the audio actually extracted at the end of media" do
    allow(TranscodeService).to receive(:extract_speech_audio) do |_url, output_path:, **_kwargs|
      File.binwrite(output_path, "RIFF" + ("\0" * 128))
      TranscodeService::AudioClipExtractionResult.new(status: :ok, bytes: File.size(output_path), duration_seconds: 5)
    end
    payload = JSON.parse(success_payload)
    payload["segments"] = [ { "text" => "Final line", "start" => 2, "end" => 20 } ]
    stub_request(:post, endpoint).to_return(status: 200, body: payload.to_json)

    result = described_class.new.translate(input_url, start_seconds: 400)

    expect(result).to be_ok
    expect(result.window_end).to eq(430)
    expect(result.cues).to eq([ { start: 402.0, end: 405.0, text: "Final line" } ])
  end

  it "keeps whole-second window precision for low-latency first requests" do
    request = stub_request(:post, endpoint).to_return(status: 200, body: success_payload)

    result = described_class.new.translate(input_url, start_seconds: 57)

    expect(result).to be_ok
    expect(result.window_start).to eq(57)
    expect(result.window_end).to eq(87)
    expect(request).to have_been_requested.once
  end

  it "rejects a provider response that did not perform English translation" do
    payload = JSON.parse(success_payload).merge("task" => "transcribe").to_json
    stub_request(:post, endpoint).to_return(status: 200, body: payload)

    result = described_class.new.translate(input_url, start_seconds: 300)

    expect(result.status).to eq(:invalid_response)
    expect(result.cues).to be_empty
  end

  it "uses a trusted audio-track language hint to skip first-window auto detection" do
    request = stub_request(:post, endpoint)
      .with { |web_request| web_request.body.include?("\r\nen\r\n") }
      .to_return(status: 200, body: success_payload)

    result = described_class.new.translate(input_url, start_seconds: 200, source_language: "ENG")

    expect(result).to be_ok
    expect(request).to have_been_requested.once
  end

  it "reuses the detected source language on following windows" do
    first = stub_request(:post, endpoint)
      .with { |request| request.body.include?("auto") }
      .to_return(status: 200, body: success_payload)
    second = stub_request(:post, endpoint)
      .with { |request| request.body.include?("\r\nfr\r\n") }
      .to_return(status: 200, body: success_payload)

    described_class.new.translate(input_url, start_seconds: 0)
    described_class.new.translate(input_url, start_seconds: 25)

    expect(first).to have_been_requested.once
    expect(second).to have_been_requested.once
  end

  it "single-flights concurrent requests for the same window" do
    extraction_calls = 0
    allow(TranscodeService).to receive(:extract_speech_audio) do |_url, output_path:, **_kwargs|
      extraction_calls += 1
      File.binwrite(output_path, "RIFF" + ("\0" * 128))
      sleep 0.1
      TranscodeService::AudioClipExtractionResult.new(status: :ok, bytes: File.size(output_path))
    end
    request = stub_request(:post, endpoint).to_return(status: 200, body: success_payload)
    gate = Queue.new

    threads = 2.times.map do
      Thread.new do
        gate.pop
        described_class.new.translate(input_url, start_seconds: 75)
      end
    end
    2.times { gate << true }
    results = threads.map(&:value)

    expect(results).to all(be_ok)
    expect(results.map(&:cues)).to all(eq(results.first.cues))
    expect(extraction_calls).to eq(1)
    expect(request).to have_been_requested.once
  end

  it "wakes concurrent waiters when local Whisper times out" do
    allow_any_instance_of(described_class).to receive(:request_inference) do
      sleep 0.1
      raise Net::ReadTimeout
    end
    gate = Queue.new
    threads = 2.times.map do
      Thread.new do
        gate.pop
        described_class.new.translate(input_url, start_seconds: 100)
      end
    end
    2.times { gate << true }

    results = threads.map { |thread| thread.value }

    expect(results.map(&:status)).to eq([ :timeout, :timeout ])
    expect(described_class.inflight).to be_empty
  end

  it "rejects a different window while the single local inference slot is occupied" do
    described_class.inference_mutex.lock

    result = described_class.new.translate(input_url, start_seconds: 150)

    expect(result.status).to eq(:busy)
    expect(TranscodeService).not_to have_received(:extract_speech_audio)
    expect(described_class.inference_mutex).to be_owned
  ensure
    described_class.inference_mutex.unlock if described_class.inference_mutex.owned?
  end

  it "does not persist or re-run cached caption audio" do
    request = stub_request(:post, endpoint).to_return(status: 200, body: success_payload)

    first = described_class.new.translate(input_url, start_seconds: 125)
    second = described_class.new.translate(input_url, start_seconds: 125.9)

    expect(second.cues).to eq(first.cues)
    expect(request).to have_been_requested.once
    expect(TranscodeService).to have_received(:extract_speech_audio).once
  end
end
