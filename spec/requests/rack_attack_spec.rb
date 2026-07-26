# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Request rate limiting", type: :request do
  around do |example|
    original_store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rack::Attack.cache.store = original_store
  end

  let(:application) { ->(_env) { [ 200, { "Content-Type" => "text/plain" }, [ "ok" ] ] } }
  let(:middleware) { Rack::Attack.new(application) }

  def post_pin(ip:)
    body = URI.encode_www_form("pin" => "0000")
    env = Rack::MockRequest.env_for(
      "/pin",
      method: "POST",
      input: body,
      "CONTENT_TYPE" => "application/x-www-form-urlencoded",
      "REMOTE_ADDR" => ip
    )

    middleware.call(env)
  end

  def authenticated_request(path, method:, user_id: 42)
    warden = Object.new
    user = Struct.new(:id).new(user_id)
    warden.define_singleton_method(:user) { |fetch: false| user }
    env = Rack::MockRequest.env_for(path, method: method, "REMOTE_ADDR" => "203.0.113.20")
    env["warden"] = warden
    middleware.call(env)
  end

  def authenticated_post(path, user_id: 42)
    authenticated_request(path, method: "POST", user_id: user_id)
  end

  it "blocks the sixth PIN attempt from the same IP" do
    statuses = 6.times.map { post_pin(ip: "203.0.113.10").first }

    expect(statuses).to eq([ 200, 200, 200, 200, 200, 429 ])
  end

  it "does not share the PIN throttle across client IPs" do
    5.times { expect(post_pin(ip: "203.0.113.11").first).to eq(200) }

    expect(post_pin(ip: "203.0.113.12").first).to eq(200)
  end

  it "allows debounced thumbnail dragging but blocks the thirty-first extraction per user" do
    statuses = 31.times.map do
      authenticated_request("/transcode/thumbnail", method: "GET").first
    end

    expect(statuses).to eq([ 200 ] * 30 + [ 429 ])
    expect(authenticated_request("/transcode/thumbnail", method: "GET", user_id: 43).first).to eq(200)
  end

  it "allows an HLS seek and recovery burst without weakening fresh stream starts" do
    hls_statuses = 7.times.map { authenticated_post("/hls/start").first }
    stream_statuses = 3.times.map { authenticated_post("/streaming").first }

    expect(hls_statuses).to eq([ 200, 200, 200, 200, 200, 200, 429 ])
    expect(stream_statuses).to eq([ 200, 200, 429 ])
  end
end
