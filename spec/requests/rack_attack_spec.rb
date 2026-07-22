# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Sign-in rate limiting", type: :request do
  around do |example|
    original_store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rack::Attack.cache.store = original_store
  end

  let(:application) { ->(_env) { [200, { "Content-Type" => "text/plain" }, ["ok"]] } }
  let(:middleware) { Rack::Attack.new(application) }

  def post_sign_in(email:, ip:)
    body = URI.encode_www_form("user[email]" => email, "user[password]" => "wrong-password")
    env = Rack::MockRequest.env_for(
      "/users/sign_in",
      method: "POST",
      input: body,
      "CONTENT_TYPE" => "application/x-www-form-urlencoded",
      "REMOTE_ADDR" => ip
    )

    middleware.call(env)
  end

  it "blocks the sixth attempt for the same normalized account and IP" do
    statuses = [
      post_sign_in(email: " Admin@NeyoBytes.com ", ip: "203.0.113.10").first,
      *4.times.map { post_sign_in(email: "admin@neyobytes.com", ip: "203.0.113.10").first },
      post_sign_in(email: "ADMIN@NEYOBYTES.COM", ip: "203.0.113.10").first
    ]

    expect(statuses).to eq([200, 200, 200, 200, 200, 429])
  end

  it "does not block another account on the same shared IP after five attempts" do
    5.times { expect(post_sign_in(email: "first@example.com", ip: "203.0.113.11").first).to eq(200) }

    expect(post_sign_in(email: "second@example.com", ip: "203.0.113.11").first).to eq(200)
  end

  it "does not share an account throttle across different client IPs" do
    5.times { expect(post_sign_in(email: "shared@example.com", ip: "203.0.113.12").first).to eq(200) }

    expect(post_sign_in(email: "shared@example.com", ip: "203.0.113.13").first).to eq(200)
  end

  it "retains an IP-wide backstop against rotating account identifiers" do
    statuses = 21.times.map do |attempt|
      post_sign_in(email: "attempt-#{attempt}@example.com", ip: "203.0.113.14").first
    end

    expect(statuses.first(20)).to all(eq(200))
    expect(statuses.last).to eq(429)
  end
end
