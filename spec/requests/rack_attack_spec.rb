# frozen_string_literal: true

require "rails_helper"

RSpec.describe "PIN rate limiting", type: :request do
  around do |example|
    original_store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rack::Attack.cache.store = original_store
  end

  let(:application) { ->(_env) { [200, { "Content-Type" => "text/plain" }, ["ok"]] } }
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

  it "blocks the sixth PIN attempt from the same IP" do
    statuses = 6.times.map { post_pin(ip: "203.0.113.10").first }

    expect(statuses).to eq([200, 200, 200, 200, 200, 429])
  end

  it "does not share the PIN throttle across client IPs" do
    5.times { expect(post_pin(ip: "203.0.113.11").first).to eq(200) }

    expect(post_pin(ip: "203.0.113.12").first).to eq(200)
  end
end
