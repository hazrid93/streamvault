require 'rails_helper'

RSpec.describe "Settings", type: :request do
  let(:user) { create(:user) }

  before do
    stub_request(:get, /www\.omdbapi\.com/)
      .to_return(status: 200, body: { "Response" => "False" }.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  describe "GET /settings" do
    context "when not authenticated" do
      it "redirects to login" do
        get settings_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "returns success" do
        get settings_path
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "PATCH /settings" do
    before { sign_in user }

    it "updates RealDebrid key and verifies" do
      stub_request(:get, "https://api.real-debrid.com/rest/1.0/user")
        .to_return(status: 200, body: { "username" => "testuser" }.to_json, headers: { 'Content-Type' => 'application/json' })

      patch settings_path, params: { user: { realdebrid_api_key: "new_key_123" } }
      expect(response).to redirect_to(settings_path)
      expect(user.reload.realdebrid_api_key).to eq("new_key_123")
    end

    it "preserves existing RD key when blank" do
      user.update!(realdebrid_api_key: "existing_key")
      patch settings_path, params: { user: { realdebrid_api_key: "" } }
      expect(user.reload.realdebrid_api_key).to eq("existing_key")
    end

    it "updates preferred languages" do
      patch settings_path, params: { user: { preferred_languages: ["ENG", "FRENCH"] } }
      expect(response).to redirect_to(settings_path)
      expect(user.reload.preferred_languages).to include("ENG", "FRENCH")
    end
  end

  describe "PATCH /settings/pin" do
    before do
      user.set_pin("1234", "1234")
      sign_in user
    end

    it "changes the PIN when the current PIN is correct" do
      patch settings_pin_path, params: {
        current_pin: "1234",
        pin: "5678",
        pin_confirmation: "5678"
      }

      expect(response).to redirect_to(settings_path)
      expect(user.reload.valid_pin?("5678")).to be(true)
      expect(user.valid_pin?("1234")).to be(false)
    end

    it "rejects an incorrect current PIN" do
      patch settings_pin_path, params: {
        current_pin: "9999",
        pin: "5678",
        pin_confirmation: "5678"
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(user.reload.valid_pin?("1234")).to be(true)
    end

    it "rejects a malformed or nonmatching new PIN" do
      patch settings_pin_path, params: {
        current_pin: "1234",
        pin: "12ab",
        pin_confirmation: "9999"
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(user.reload.valid_pin?("1234")).to be(true)
    end
  end

  describe "RD key exposure (SEC-08)" do
    before { sign_in user }

    it "does not leak the plaintext RD key in the settings page body" do
      user.update!(realdebrid_api_key: "SECRET_KEY_DO_NOT_LEAK")
      get settings_path
      expect(response.body).not_to include("SECRET_KEY_DO_NOT_LEAK")
    end
  end
end
